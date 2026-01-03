module Conv #(
        parameter INW = 12,
        parameter R = 9,
        parameter C = 8,
        parameter MAXK = 5,
        localparam OUTW = $clog2(MAXK*MAXK*(128'd1 << 2*INW-2) + (1<<(INW-1)))+1,
        localparam K_BITS = $clog2(MAXK+1),
        localparam DEPTH = C-1,
        localparam PIPELINE_DEPTH = 2, //used for generating how many times to stall pipeline before FIFO accepts
        localparam PIPELINE_DEPTH_BITS = $clog2(PIPELINE_DEPTH + 1),
        localparam X_ADDR_BITS = $clog2((R*C)),
        localparam W_ADDR_BITS = $clog2(MAXK*MAXK),
        localparam ROW_ADDR_BITS = $clog2(R+1),
        localparam COL_ADDR_BITS = $clog2(C), 
        localparam COL_INCR_BITS = $clog2(C+1)// needs to be C + 1, because if incrementing by 16, we need 
                                                // 5 bits, not 4
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
        LOAD_MAC,
        WRITE_DATA
    } state, next_state;

    logic [ K_BITS - 1 : 0 ] incr_baseaddr_amt; //amount to increment baseaddr by (either 1 or K based on
                                    // if we are going to next row or not for base of conv. window)
                                    
    logic incr_baseaddr; //control signal to determine whether or not to increment base address (when i and j == K - 1)
    logic clr_x_base_addr;

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

    logic clr_i;
    logic incr_i;
    logic [ K_BITS - 1 : 0 ] out_i;
    logic max_i;

    logic clr_j;
    logic incr_j;
    logic [ K_BITS - 1 : 0 ] out_j;
    logic max_j;

    //Signals for actual address (not incrementer) for i offset
    logic [ X_ADDR_BITS - 1 : 0 ] out_i_addr ;

    //Signals for W counter
    logic clr_w;
    logic incr_w;


    //signal to pulse when for 1 clock cycle when we're done with our computation
    logic compute_finished; 

    //Input memories variables
    // Signal to indicate if all inputs are loaded or not (output of input mems)
    logic inputs_loaded;

    // Signal to indicate what K is
    logic [ K_BITS - 1 : 0 ] K;

    // Signal to indicate bias
    logic [ INW - 1 : 0 ] B;

    // X data output of X memory (from input mems)
    logic [ INW - 1 : 0 ] X_data;
    logic [ X_ADDR_BITS - 1 : 0 ] X_read_addr;

    //// W data output of W memory (from input mems)
    logic [ INW - 1 : 0 ] W_data;
    logic [ W_ADDR_BITS - 1 : 0 ] W_read_addr;

    //Mac variables
    logic input_valid;
    logic init_acc;
    logic [ OUTW - 1 : 0 ] mac_out; //shared with FIFO

    //Mac counter variables
    logic [ PIPELINE_DEPTH_BITS - 1 : 0 ] out_mac_count;
    logic incr_mac_count;
    logic clr_mac_count;

    //FIFO variables
    logic IN_AXIS_TREADY; //output from FIFO
    logic IN_AXIS_TVALID; //input to FIFO

    // ============== Begin Base address logic (used for base address of convolution addresses) =======

    // ALSO included here is the code for keeping track of where we are in the X matrix

    //Set the amount to increment base address by K or 1 depending on if we reached the end of the row or not

    //Increment by K if we reach the end of the row (we performed C - K multiplications/convolutions)
    //To do so, set C counter to 0, and increment R counter by C

    // ALSO, we need R - K to keep track of total amount of times we need to repeat this process
    //if it reaches C - K ( C - K + 1 is the amount of times we do MAC ( K * K times) per row ), 
    //that means now we need to go to next row, so instead of incrementing by 1, we increment by K
    //In doing this, we don't use multiplication, but addition when calculating next offset
    //so hopefully when we optimize this code, there will not be a bottleneck from address calculation
    //This is unnecessary, but I thought it would be a fun challenge.

    assign incr_baseaddr_amt = (max_c == 1) ? K : 1; // increment base address by K or by 1 depdning on 
                                                    // if we reached the end of the row (last column) or not

    // X address = base address + i (C*i because row address = C*i) + j (because j is offset)
    assign X_read_addr = (x_base_addr + out_j + out_i_addr);

    //used for the base address value
    var_incr_reg  #(
        .OUTW(X_ADDR_BITS),
        .MAX_INCR_BITS(K_BITS)
    ) baseaddr_reg(
        .incr_amt(incr_baseaddr_amt), // output of mux whose select is generated by control unit
        .incr(incr_baseaddr),
        .clr(clr_x_base_addr),
        .reset(reset),
        .clk(clk),
        .out(x_base_addr)
    );

    //keep track of column we're on
    counter_with_clr #(
        .OUTW(COL_ADDR_BITS)
    ) C_counter (
        .clk(clk),
        .reset(reset),
        .clr(clr_c),
        .incr(incr_c),
        .out(out_c)
    );

    //if out_c = C - K, we reached the end of the columns 
    assign max_c = (out_c == C - K);

    //keep track of row we're on
    counter_with_clr #(
        .OUTW(ROW_ADDR_BITS)
    ) R_counter (
        .clk(clk),
        .reset(reset),
        .clr(clr_r),
        .incr(incr_r),
        .out(out_r)
    );

    //if out_r = R - K, we reached the end of the rows needed for convolution (wait to perform C - K more times)
    assign max_r = (out_r == R - K);

    // ============== End Base address logic ==============

    // ============== Begin MAC for ONE WINDOW logic ==============
    //K * K window, use counters to perform arithmetic
    counter_with_clr #(
        .OUTW(K_BITS) //K_BITS because max value could be K - 2
    ) j_counter(
        .clk(clk),
        .reset(reset),
        .clr(clr_j),
        .incr(incr_j),
        .out(out_j)
    );

    assign max_j = (out_j == K - 1) ? 1 : 0; //calculate when we are done with the last column (go to next row)
                                                // (of weight matrix)
    //keep track of how many times we've changed rows (when that == K - 1, we are on our last row)
    counter_with_clr #(
        .OUTW(K_BITS)
    ) i_counter(
        .clk(clk),
        .reset(reset),
        .clr(clr_i),
        .incr(incr_i),
        .out(out_i)
    );

    assign max_i = (out_i == K - 1) ? 1 : 0; //calculate when we are on the last row of weight matrix
    //Note: if (max_i == 1 && max_j == 1) then increment base address

    var_incr_reg  #(
        .OUTW(X_ADDR_BITS), //X_ADDR_BITS because max value could be R * C  - 1
        .MAX_INCR_BITS(COL_INCR_BITS)
    ) i_address_counter ( //register that keeps track of what the offset (for the row) we are from the base address
        .incr_amt(COL_INCR_BITS'(C)), // amount to increment i by (C because j resets + we go to next row, starting from j = 0)
        .incr(incr_i), // increment by C if max_j is asserted (we were on the last column, so go to next row)
        .clr(clr_i), //generated from state machine
        .reset(reset),
        .clk(clk),
        .out(out_i_addr) //out_i_addr <= out_i_addr + C when max_j == 1
    );

    //keep track of w address (easiest part of window multiplication, because it's purely sequential)
       counter_with_clr #(
        .OUTW(W_ADDR_BITS) 
    ) w_counter(
        .clk(clk),
        .reset(reset),
        .clr(clr_w),
        .incr(incr_w),
        .out(W_read_addr)
    );

    // ============== End MAC for ONE WINDOW logic ==============

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
        .K(K),
        .B(B),
        .X_read_addr(X_read_addr),
        .X_data(X_data),
        .W_read_addr(W_read_addr),
        .W_data(W_data)
    );

    mac_pipe #(
        .INW(INW),
        .OUTW(OUTW)
    ) mac(
        .input0(X_data),
        .input1(W_data),
        .init_value(B),
        .out(mac_out),
        .clk(clk),
        .reset(reset),
        .init_acc(init_acc), 
        .input_valid(input_valid)
    );

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
        .IN_AXIS_TDATA(mac_out),
        .IN_AXIS_TVALID(IN_AXIS_TVALID), 
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
        clr_i = 0;
        incr_i = 0;

        clr_j = 0;
        incr_j = 0;

        clr_r = 0;
        incr_r = 0;

        clr_c = 0;
        incr_c = 0;

        clr_w = 0;
        incr_w = 0;

        clr_x_base_addr = 0;
        incr_baseaddr = 0;

        incr_mac_count = 0;
        clr_mac_count = 0;

        IN_AXIS_TVALID = 0;

        input_valid = 0;
        init_acc = 0;

        compute_finished = 0;

        if (state == WAIT_FOR_LOAD) begin
            //Clear all registers when in WAIT_FOR_LOAD state (and inputs not loaded)
            if ( inputs_loaded == 0 ) begin
                clr_i = 1;
                clr_j = 1;
                clr_w = 1;
                clr_c = 1;
                clr_r = 1;
                clr_x_base_addr = 1;
                clr_mac_count = 1;
            end
            else begin //inputs_loaded == 1
                //only can do this if we're ready to receieve new data
                    init_acc = 1; //init_acc is valid, because start of new W * X multiplication
                    //prepare next data
                    incr_w = 1;
                    incr_j = 1;
            end
        end
        else if (state == LOAD_MAC) begin
            input_valid = 1;
            if(out_mac_count == 0) incr_w = 1; //increment w only when out_mac_count = 0
            if(out_mac_count != 0 && out_mac_count != 1) begin
                    //if mac count > 1, that means we no longer expect valid data on input
                    input_valid = 0;
                end
            if (max_j == 1 || out_mac_count != 0) begin // if max_j = 1 or we're using the mac to increment
                if(max_i == 1 || out_mac_count != 0) begin //if max_i and max_j = 1 or we're using mac to increment
                    if(out_mac_count != (PIPELINE_DEPTH)) begin //pipeline_depth because we have valid inputs 2 times (when max_i and max_j = 1 and the clock cycle after (when data from max_j =1 and max_i = 1 is ready))
                        incr_mac_count = 1; //once mac count == PIPELINE_DEPTH, stop incrementing mac count, and assert valid input
                                            //however, once out_mac_count == PIPELINE_DEPTH, it's ready on next clock cycle (which is seen in the write_data state)
                    end
                    else begin 
                        // IN_AXIS_TVALID = 1; //input is valid on MAC
                        if( IN_AXIS_TREADY == 1 ) begin
                            //only increment j and w if the FIFO is ready to receive data
                            incr_j = 1;
                            incr_w = 1;
                        end
                    end
                        
                    if(out_mac_count == 0 || out_mac_count == 1) begin
                        //it's only a valid input when out_mac_count == 0 or out_mac_count == 1 and max_i == 1 and max_j == 1
                        input_valid = 1;
                        if ( out_mac_count == 1 ) begin
                            //prepare data when out_mac_count is 1 so it resets the state to in
                            clr_j = 1; //reset counter for j for next clock cycle
                            clr_i = 1; //reset counter for i
                            clr_w = 1; //reset counter for w
                            incr_baseaddr = 1; //go to next address
                        end
                    end
                end
                else begin //max_j = 1 and max_i != 1
                    clr_j = 1;
                    incr_i = 1;
                end
            end
            else begin //max_j != 1
                //increment j only if out_mac_count = 0 or IN_AXIS_TREADY is 1
                if(out_mac_count == 0 || IN_AXIS_TREADY == 1) incr_j = 1; 
            end
        end
        else if ( state == WRITE_DATA ) begin
            //if we reach this state, IN_AXIS_TREADY = 1
            IN_AXIS_TVALID = 1;
            init_acc = 1; //initialize next bias
            input_valid = 1; //inputs are valid
            
            //increment j logic (because K can be as low as 2 (edge case)...which means j can be 1 and needs
            //to roll over)
            if(max_j == 1) begin
                clr_j = 1;
                incr_i = 1;
            end
            else incr_j = 1; //prepare to increment j

            incr_w = 1; //prepare to increment w
            clr_mac_count = 1; //reset mac counter

            incr_c = 1; //go to next column
                if ( max_c == 1 ) begin
                    if(max_r == 1 ) begin
                    //if we execute this block, that means we're transitioning back to WAIT_FOR_LOAD stage,
                    //so we need to reset system
                    clr_i = 1;
                    clr_j = 1;
                    clr_w = 1;
                    clr_c = 1;
                    clr_r = 1;
                    clr_x_base_addr = 1;
                    clr_mac_count = 1;
                    compute_finished = 1;
                    init_acc = 0;
                    end
                    else begin //max_c == 1, but max_r != 1
                        clr_c = 1; //clr_c has precedence over incr_c, so reset c counter
                        incr_r = 1; //go to next row
                    end
                end

            end
    end

    always_comb begin : next_state_logic
        if ( state == WAIT_FOR_LOAD ) begin
            //if inputs are loaded, we can load the mac
            if ( inputs_loaded == 1 ) begin
                next_state = LOAD_MAC; // start loading MAC
            end
            else begin
                next_state = WAIT_FOR_LOAD; //otherwise, if inputs_loaded != 1, stay in state
            end
        end
        else if ( state == LOAD_MAC ) begin
            //if FIFO is ready, and we have finished a computation, write data
            if ( IN_AXIS_TREADY == 1 && out_mac_count == PIPELINE_DEPTH) begin
                next_state = WRITE_DATA;
            end
            else begin //otherwise, stay in this state
                next_state = LOAD_MAC;
            end
        end
        else if ( state == WRITE_DATA ) begin
            //if end of convolution (specified by max_r and max_c being 1, ), repeat process
            //by going to read next input
            if ( ( max_c == 1 ) && ( max_r == 1 ) ) begin
                next_state = WAIT_FOR_LOAD;
            end
                
            else begin //otherwise, go to load data again
                //if this if statement was hit, that means we're going to load the MAC again              
                next_state = LOAD_MAC;
            end
        end
        else next_state = WAIT_FOR_LOAD; //shouldn't need this, but to be safe for no implied latch
    end

    // ================ State Machine Logic End ================

endmodule