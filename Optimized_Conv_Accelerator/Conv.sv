module Conv #(
        parameter INW = 24,
        parameter R = 16,
        parameter C = 17,
        parameter MAXK = 9,
        localparam N = MAXK*MAXK,
        localparam OUTW = $clog2(MAXK*MAXK*(128'd1 << 2*INW-2) + (1<<(INW-1)))+1,
        localparam K_BITS = $clog2(MAXK+1),
        localparam DEPTH = 2*(R-1)*(C-1), //have space for two output matrices
        localparam X_ADDR_BITS = $clog2((R*C)),
        localparam W_ADDR_BITS = $clog2(MAXK*MAXK),
        localparam ROW_ADDR_BITS = $clog2(R+1),
        localparam COL_ADDR_BITS = $clog2(C), 
        localparam COL_INCR_BITS = $clog2(C+1),// needs to be C + 1, because if incrementing by 16, we need 
                                                // 5 bits, not 4
        localparam ADDER_TREE_STAGES = $clog2(MAXK*MAXK), //deteremine how many stages the adder tree should be
        localparam ADDER_TREE_MAX = 1 << ADDER_TREE_STAGES,
        localparam PIPELINE_DEPTH = ADDER_TREE_STAGES + 1 + 4 + 1, //+1 - input reg (before mult), another + 4 for mult, another + 1 for register between last adder + bias adder
        localparam LOGDEPTH = $clog2(DEPTH), //used for FIFO capacity 
        localparam PIPELINE_DEPTH_BITS = $clog2(PIPELINE_DEPTH + 1)
    )(
        input clk,
        input reset,
        input [INW-1:0] INPUT_TDATA,
        input INPUT_TVALID,
        input [K_BITS:0] INPUT_TUSER,
        output logic INPUT_TREADY,
        output logic [OUTW-1:0] OUTPUT_TDATA,
        output OUTPUT_TVALID,
        input OUTPUT_TREADY
    );

    enum logic [ 1 : 0 ] {
        WAIT_FOR_LOAD,
        LOAD_DATA,
        WAIT_FOR_PIPE
    } state, next_state;

    logic incr_baseaddr; //control signal to determine whether or not to increment base address (when i and j == K - 1)
    // Signal used to keep track of base address (used in addition for r and c to calculate 
    // memory address for X in X[r+i][c+j] * W[i][j]
    logic [ X_ADDR_BITS - 1 : 0 ] x_base_addr; //base address which generates all addresses for kernel

    //Signals for counting which column we are on (logic for multiplying X * W)
    logic max_c; //determine when we reach the end of the column (go to next row)
    logic clr_c;
    logic incr_c;
    logic [ COL_ADDR_BITS - 1 : 0 ] out_c;

    logic max_r; //determine when we reach the end of the column (go to next row)
    logic clr_r;
    logic incr_r;
    logic [ ROW_ADDR_BITS - 1 : 0 ] out_r;

    //signal to pulse when for 1 clock cycle when we're done with our computation
    logic compute_finished; 

    //Input memories variables
    // Signal to indicate if all inputs are loaded or not (output of input mems)
    logic inputs_loaded;

    // Signal to indicate what K is
    logic [ K_BITS - 1 : 0 ] K;

    // Signal to indicate bias
    logic signed [ INW - 1 : 0 ] B;

    logic [ X_ADDR_BITS - 1 : 0 ] X_read_addr;


    //Mac variables
    logic input_valid;
    logic init_acc;
    logic signed [ OUTW - 1 : 0 ] mac_out; //shared with FIFO

    //Mac counter variables
    logic [ PIPELINE_DEPTH_BITS - 1 : 0 ] out_mac_count;
    logic incr_mac_count;
    logic clr_mac_count;

    //FIFO variables
    logic IN_AXIS_TREADY; //output from FIFO
    logic IN_AXIS_TVALID; //input to FIFO
    logic [LOGDEPTH : 0] fifo_capacity;

    //Line Buffer + Multiplier/Adder Tree logic
    //Line buffer input
    logic pixel_valid; //indicates to buffer we're sending vallid data from X memory

    logic [INW - 1 : 0] packed_window_data [MAXK * MAXK - 1 : 0];
    logic signed [INW - 1 : 0] W_matrix [MAXK * MAXK];
    
    logic signed [INW - 1 : 0] mult_inp_reg_X [ADDER_TREE_MAX- 1 : 0]; //these X and W registers
    logic signed [INW - 1 : 0] mult_inp_reg_W [ADDER_TREE_MAX - 1 : 0];

    //Line buffer outputs / adder tree + mult signals
    logic [INW - 1 : 0] window_out [MAXK - 1 : 0][MAXK - 1 : 0]; //output of input_mems for showing 
                                                                //correct windowed data (in parallel)
    logic window_valid; //indicate we're reading valid window data
    logic signed [2 * INW - 1 : 0] mult_out [ADDER_TREE_MAX - 1 : 0]; //we need MAXK^2 multipliers
    logic signed [2 * INW - 1 : 0] mult_out_reg [ADDER_TREE_MAX - 1 : 0]; //If we have MAXK^2 multipliers, we need MAXK^2 registers

    logic ld_mult; //control for multiiplier register (leading to input to multipliers)

    logic signed [OUTW - 1 : 0] adder_tree_reg [0:ADDER_TREE_STAGES-1][0:ADDER_TREE_MAX/2-1];
    logic init_valid;
    logic input_valid_reg[PIPELINE_DEPTH];
    logic init_X_addr; //control signal used to setup the counter after pre-fetching data in WAIT_FOR_LOAD state

    // ============== Begin Base address logic (used for base address of convolution addresses) =======

    always_ff @(posedge clk) begin : X_addr
        if(reset) X_read_addr <= 0;
        else if(init_X_addr) X_read_addr <= (K-1)*C + (K); //initial value is whatever K -1 times C + K is (based off counter from window going up to K -1)
        else if(incr_baseaddr) X_read_addr <= X_read_addr + 1; //increment X read address
    end

    always_ff @(posedge clk) begin : C_counter
        if(reset) out_c <= 0;
        else if(clr_c) out_c <= 0;
        else if(incr_c) out_c <= out_c + 1;
    end

    //if out_c == K, we reached the end of the columns 
    assign max_c = (out_c == C - 1);

    always_ff @(posedge clk) begin : R_counter
        if(reset) out_r <= 0;
        else if(clr_r) out_r <= 0;
        else if(init_X_addr) out_r <= K;
        else if(incr_r) out_r <= out_r + 1;
    end

    //if out_r == R, we reached the end of the rows
    assign max_r = (out_r == R - K);

    // ============== End Base address logic ==============

    // Input memory structural instantiation
    input_mems #(
        .INW(INW),
        .R(R),
        .C(C),
        .MAXK(MAXK)
    )
    input_memories(
        .clk(clk),
        .reset(reset),
        .AXIS_TDATA(INPUT_TDATA),
        .AXIS_TVALID(INPUT_TVALID),
        .AXIS_TUSER(INPUT_TUSER),
        .AXIS_TREADY(INPUT_TREADY),
        .inputs_loaded(inputs_loaded),
        .compute_finished(compute_finished),
        .pixel_valid(pixel_valid),

        .K(K),
        .B(B),
        .X_read_addr(X_read_addr),
        .W_matrix(W_matrix),
        .window_out(window_out),
        .window_valid(window_valid)
    );

    always_comb begin : create_packed_data
        int idx;
        idx = 0;
        for(int i = 0; i < MAXK*MAXK; i=i+1) begin
            packed_window_data[i] = 0; //fill array with 0 (base condition)
        end
        for(int r=0; r < MAXK; r=r+1) begin
            for(int c = 0; c < MAXK; c=c+1) begin
                if(r < K && c < K) begin
                    packed_window_data[idx] = window_out[r][c]; //package data to make it easier when sending through
                                                                //multipliers + adder tree
                    idx = idx + 1; //increment index
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        for(int i = 0; i < PIPELINE_DEPTH; i++) begin
            if(reset) input_valid_reg[i] <= 0;
        end
        input_valid_reg[0] <= ld_mult;
        for(int i = 1; i < PIPELINE_DEPTH; i++) begin
            input_valid_reg[i] <= input_valid_reg[i-1];
        end
    end

    always_ff @(posedge clk) begin : load_input_multiplier_register
        for(int i = 0; i < ADDER_TREE_MAX; i=i+1) begin //load the multiplier inputs
            if(reset) begin
                mult_inp_reg_W[i] <= 0;
                mult_inp_reg_X[i] <= 0;

            end
            else if (ld_mult) begin //control signal to load the multiplier register
                if(i < K * K) begin
                    mult_inp_reg_X[i] <= packed_window_data[i]; //parallel load X matrix into multiplier register (before passing into multiplier... Prof. Milder said to do this)
                    mult_inp_reg_W[i] <= W_matrix[i]; //parallel load W matrix into multiplier register
                end
                else begin
                    mult_inp_reg_X[i] <= 0; //load 0s into the adder tree
                    mult_inp_reg_W[i] <= 0; 
                end
            end
        end
    end
    //Replace this logic with multiplier + adder tree
    genvar m;
    generate
        for(m = 0; m < ADDER_TREE_MAX; m=m+1) begin : mult_piped //we need MAXK^2 multipliers
            DW02_mult_5_stage #(
                .A_width(INW), 
                .B_width(INW)
            ) mult_5_stage (
                .A(mult_inp_reg_X[m]),
                .B(mult_inp_reg_W[m]),
                .TC(1'b1),
                .CLK(clk),
                .PRODUCT(mult_out[m])
            );
        end
    endgenerate

    always_ff @(posedge clk) begin : mult_add_pipeline_register
        for(int i = 0; i < ADDER_TREE_MAX; i=i+1) begin
            if(reset) mult_out_reg[i] <= 0; //reset mult_out register
            else mult_out_reg[i] <= mult_out[i]; //mult_out pipeline register between mults and adder tree
        end
    end

    genvar stage, n;
    generate
        for(n = 0; n < ADDER_TREE_MAX/2; n=n+1) begin
            always_ff @(posedge clk) begin
                adder_tree_reg[0][n] <= mult_out_reg[2*n] + mult_out_reg[2*n+1]; //adder tree stage 0
            end
        end
        for(stage = 1; stage < ADDER_TREE_STAGES; stage=stage+1) begin //amount of times we need to repeat this
                                                                    //(the amount of stages we have)
            for(n = 0; n < (ADDER_TREE_MAX / (2*(stage+1))); n=n+1) begin //generate next power of 2 from MAXK^2 
                always_ff @(posedge clk) begin
                    if(reset) begin
                        adder_tree_reg[stage][n] <= 0;
                    end
                    else begin
                        adder_tree_reg[stage][n] <= adder_tree_reg[stage-1][2*n] + adder_tree_reg[stage-1][2*n+1];
                    end
                end
            end
        end
    endgenerate

    assign mac_out = adder_tree_reg[ADDER_TREE_STAGES - 1][0] + B; //assign output of adder tree to mac_out (used for FIFO)

    //used to count how many cycles for multiplier + adder tree
    counter_with_clr #(
        .OUTW(PIPELINE_DEPTH_BITS)
    ) mac_counter(
        .clk(clk),
        .reset(reset),
        .clr(clr_mac_count),
        .incr(incr_mac_count),
        .out(out_mac_count)
    );

    fifo_out #(
        .OUTW(OUTW),
        .DEPTH(DEPTH)
    ) output_fifo(
        .clk(clk),
        .reset(reset),
        .capacity(fifo_capacity),
        .IN_AXIS_TDATA(mac_out),
        .IN_AXIS_TVALID(input_valid_reg[PIPELINE_DEPTH-1]), 
        .IN_AXIS_TREADY(IN_AXIS_TREADY),
        .OUT_AXIS_TDATA(OUTPUT_TDATA),
        .OUT_AXIS_TVALID(OUTPUT_TVALID),
        .OUT_AXIS_TREADY(OUTPUT_TREADY)
    );

    // ================ State Machine Logic Begin ================

    always_ff @(posedge clk) begin : state_logic
        if(reset) state <= WAIT_FOR_LOAD;
        else state <= next_state;
    end

    always_comb begin : output_comb

        clr_r = 0;
        incr_r = 0;

        clr_c = 0;
        incr_c = 0;

        incr_baseaddr = 0;

        incr_mac_count = 0;
        clr_mac_count = 0;

        IN_AXIS_TVALID = 0;

        input_valid = 0;
        init_acc = 0;

        compute_finished = 0;
        
        //newly added control signals for part 5
        ld_mult = 0;
        init_X_addr = 0;
        pixel_valid = 0;

        if (state == WAIT_FOR_LOAD) begin
            //Clear all registers when in WAIT_FOR_LOAD state (and inputs not loaded)
            if ( inputs_loaded == 0 ) begin
                clr_c = 1;
                clr_r = 1;
                clr_mac_count = 1;
                init_X_addr = 1; //once we've loaded K, this will compute base address to read from
            end
            else begin //inputs_loaded == 1
                if(fifo_capacity >= (DEPTH >> 1)) begin //if capacity >= depth / 2, give control to datapath (perform entire convoluion) 
                    incr_baseaddr = 1; //get new memory address (the data at the 0th column, Kth row is being fetched on this cycle)
                end
            end
        end
        else if (state == LOAD_DATA) begin
            //Once we're in this state, we just need to keep sending data. This SHOULD be straightforward
            incr_baseaddr = 1; //continue incrementing base address
            pixel_valid = 1; //we have valid data on the X data line, so read it into line buffer
            if(out_c <= C - K) ld_mult = 1;
            // if (out_mac_count != PIPELINE_DEPTH - 1) incr_mac_count = 1;
            // else IN_AXIS_TVALID = 1;

            if ( max_r != 1 ) begin //if max_r != 1, we can increment the counters
                if(max_c == 1 ) begin
                    clr_c = 1; //so reset c counter
                    incr_r = 1; //go to next row
                    //NOTE: C and R registers point DIRECTLY to the read adderss, so 
                    //when they're at their max value, the X address will read the new data on the next clock cycle
                end
                else begin  //max_r == 1
                    incr_c = 1; //go to next column
                    if(max_c == 1) clr_mac_count = 1; // reset MAC counter
                end
                //if we execute this block, that means we're done inputting into the multipler + adder tree,
                //wait for ADDER_TREE_STAGES + 1
                end
            else begin
                if(max_c != 1) incr_c = 1; // increment c until it reaches max_c
                if(max_c == 1) clr_mac_count = 1; //clear mac count once max_c is 1
            end
        end
        else if ( state == WAIT_FOR_PIPE ) begin
            if(out_mac_count == 0) begin 
                pixel_valid = 1; //if this is first iteration, that means pixel_valid 
                                                    //should be 1 (last valid data into pipeline)
                if(out_c <= C - K) ld_mult = 1;
            end
            if (out_mac_count != (PIPELINE_DEPTH-1) ) begin 
                incr_mac_count = 1; //first +1 for initial registers before mult
                                     //second + 1 for MULT_PIPE_STAGES - 1 (# of registers in multiplier)
            end
            else begin //if we're here, we're aboout to reset the system
                compute_finished = 1;
                clr_c = 1; 
                clr_r = 1;
            end
        end
    end

    always_comb begin : next_state_logic
        if ( state == WAIT_FOR_LOAD ) begin
            //if inputs are loaded, we can load the data (assuming we have enough capacity left in the FIFO)
            if ( inputs_loaded == 1 ) begin
                if(fifo_capacity >= (DEPTH >> 1)) next_state = LOAD_DATA;
                else next_state = WAIT_FOR_LOAD; // start loading MAC
            end
            else begin
                //otherwise, if inputs_loaded != 1, stay in state
                next_state = WAIT_FOR_LOAD;
            end
        end
        else if ( state == LOAD_DATA ) begin
            //if end of convolution (specified by max_r and max_c being 1, ), repeat process
            //by going to read next input
            if ( ( max_c == 1 ) && ( max_r == 1 ) ) begin
                next_state = WAIT_FOR_PIPE;
            end
                
            else begin //otherwise, go to load data again
                //if this if statement was hit, that means we're going to load the MAC again              
                next_state = LOAD_DATA;
            end
        end
        else if ( state == WAIT_FOR_PIPE ) begin
            if ( out_mac_count == PIPELINE_DEPTH-1) next_state = WAIT_FOR_LOAD;
            else next_state = WAIT_FOR_PIPE;
        end
        else next_state = WAIT_FOR_LOAD; //shouldn't need this, but to be safe for no implied latch
    end

    // ================ State Machine Logic End ================

endmodule