module input_mems #(
        parameter INW = 10,
        parameter R = 15,
        parameter C = 13,
        parameter MAXK = 7,
        localparam K_BITS = $clog2(MAXK+1),
        localparam X_ADDR_BITS = $clog2(R*C),
        localparam W_ADDR_BITS = $clog2(MAXK*MAXK),
        localparam W_ADDR_SIZE = MAXK*MAXK,
        localparam X_ADDR_SIZE = R*C
    )(
        input clk, reset,
        input [INW-1:0] AXIS_TDATA,
        input AXIS_TVALID,
        input [K_BITS:0] AXIS_TUSER,
        output logic AXIS_TREADY,
        output logic inputs_loaded,
        input compute_finished,
        output logic [K_BITS-1:0] K,
        output logic signed [INW-1:0] B,
        input [X_ADDR_BITS-1:0] X_read_addr,
        output logic signed [INW-1:0] X_data,
        input [W_ADDR_BITS-1:0] W_read_addr,
        output logic signed [INW-1:0] W_data
    );
    
    
    //store K value
    logic [$clog2(MAXK+1)-1:0] TUSER_K;

    //logic for storing X
    logic incr_x;
    logic rst_x_ctr;
    logic x_ctr_reset_en;
    logic [ X_ADDR_BITS - 1 : 0 ] X_write_addr;
    logic X_wr_en;
    logic [ X_ADDR_BITS - 1 : 0 ] X_mux_addr;

    //logic for storing W
    logic incr_w;
    logic rst_w_ctr;
    logic w_ctr_reset_en;
    logic [ W_ADDR_BITS - 1 : 0 ] W_write_addr;
    logic W_wr_en;
    logic [ W_ADDR_BITS - 1 : 0 ] W_mux_addr;

    // Use this signal to determine whether we will need to load W matrix and bias B again
    // Use last bit in AXIS_TUSER as control bit
    logic new_W;

    // B enable
    logic ld_B;

    // K enable
    logic ld_K;

    // Max value is W_ADDR_BITS long to store 
    // value of last write into W memory (used for transitioning to load B value)
    logic [ W_ADDR_BITS - 1 : 0 ] last_w_idx;
    
    // FSM possible states for control logic
    enum logic [ 2 : 0 ] { 
        WAIT_FOR_READY, 
        LOAD_W_MATRIX,
        LOAD_B_VAL,
        LOAD_X_MATRIX,
        LOAD_DONE
    } state, next_state;
    
    // =========================== Datapath Logic Begin ===========================
    
    // Use TUSER_K for K value
    assign TUSER_K = AXIS_TUSER[$clog2(MAXK+1):1];
    
    assign new_W = AXIS_TUSER[0];

    // allow either system reset or custom reset to control x counter reset
    assign x_ctr_reset_en = reset | rst_x_ctr;

    // allow either system reset or custom reset to control w counter reset
    assign w_ctr_reset_en = reset | rst_w_ctr;

    //Incrementer for loading X matrix
    counter #(
              .OUT_WIDTH(X_ADDR_BITS)
    ) X_counter(
              .clk(clk), 
              .reset(x_ctr_reset_en), 
              .incr(incr_x), 
              .out(X_write_addr)
              );

    // 2:1 mux for address selection in the X memory
    mux_2_1 #(
              .DATA_WIDTH(X_ADDR_BITS)
    ) X_addr_mux(
               .in0(X_read_addr),
               .in1(X_write_addr),
               .sel(AXIS_TREADY),
               .out(X_mux_addr)
                );

    // X memory for storing X matrix
    memory #(
            .WIDTH(INW),
            .SIZE(X_ADDR_SIZE)
    ) X_memory(
            .data_in(AXIS_TDATA),
            .data_out(X_data),
            .addr(X_mux_addr),
            .clk(clk),
            .wr_en(X_wr_en)
            );

    // Incrementer for loading W matrix
    counter #(
        .OUT_WIDTH(W_ADDR_BITS)
    ) W_counter(
              .clk(clk), 
              .reset(w_ctr_reset_en), 
              .incr(incr_w), 
              .out(W_write_addr));

    // 2:1 mux for address selection in the W memory
    mux_2_1 #(
              .DATA_WIDTH(W_ADDR_BITS)
    ) W_addr_mux(
               .in0(W_read_addr),
               .in1(W_write_addr),
               .sel(AXIS_TREADY),
               .out(W_mux_addr)
                );

    // X memory for storing X matrix
    memory #(
            .WIDTH(INW),
            .SIZE(W_ADDR_SIZE)
    ) W_memory(
            .data_in(AXIS_TDATA),
            .data_out(W_data),
            .addr(W_mux_addr),
            .clk(clk),
            .wr_en(W_wr_en)
        );

    // D-type register with Load signal for B value
    ld_reg #(
        .WIDTH(INW)
    ) B_reg(
        .in(AXIS_TDATA),
        .reset(1'b0),
        .clk(clk),
        .ld(ld_B),
        .out(B)
    );

    // D-type register with load signal for K value
    ld_reg #(
        .WIDTH(K_BITS)
    ) K_reg(
        .in(TUSER_K),
        .reset(1'b0),
        .clk(clk),
        .ld(ld_K),
        .out(K)
    );

    // Combinational logic to determine what the last value we need to count to for 
    // W matrix is
    assign last_w_idx = K * K - 1; // If K == 3, last index in W matrix is 8 (3 * 3 - 1)

    // =========================== Datapath Logic End ===========================
    
    // =========================== Control Logic Begin ===========================

        always_ff @(posedge clk) begin : state_logic
            if ( reset == 1'b1 ) state <= WAIT_FOR_READY;
            else state <= next_state;
        end
        
        always_comb begin : output_comb
            // Default values (disable)
            // W matrix control signals
            incr_w = 0; // Increment addr counter?
            W_wr_en = 0; // Set memory write enable?
            rst_w_ctr = 0; // Reset counter?

            // X matrix control signals
            incr_x = 0; // Increment addr counter?
            X_wr_en = 0; // Set memory write enable?
            rst_x_ctr = 0; // Reset counter?

            //Control signal set after we load X matrix
            inputs_loaded = 0;
            
            // K control signal
            ld_K = 0;

            // B control signal
            ld_B = 0;

            // Assume we're ready for data
            AXIS_TREADY = 1;

            if ( state == WAIT_FOR_READY ) begin
                // If we're on the first cycle of loading data, and we're getting valid data
                // That means we read in W and K
                if ( AXIS_TVALID == 1'b1 ) begin
                    if ( new_W == 1'b1 ) begin 
                        // If we're writing a new W, generate these controls
                        ld_K = 1;
                        W_wr_en = 1; //Write to W memory the value of the counter
                        incr_w = 1; //Increment counter for addressing the W matrix
                    end
                    else begin
                        // Otherwise we're generate controls to write X
                        X_wr_en = 1;
                        incr_x = 1;
                    end
                end
            end
            else if ( state == LOAD_W_MATRIX ) begin
                // If valid data, write the data and increment address, otherwise don't
                if( AXIS_TVALID == 1'b1 ) begin
                    W_wr_en = 1; //Write to W memory the value of the counter
                    incr_w = 1; //Increment counter for addressing the W matrix
                end
            end
            else if ( state == LOAD_B_VAL ) begin
                // If valid data, load b register
                if( AXIS_TVALID == 1'b1 ) begin
                    // Load B value
                    ld_B = 1;
                end
            end
            else if ( state == LOAD_X_MATRIX ) begin
                if( AXIS_TVALID == 1'b1 ) begin
                    X_wr_en = 1; //Write to X memory the value of the counter
                    incr_x = 1; //Increment counter for addressing the X matrix
                end
                //otherwise don't write matrix value or increment x counter
            end
            else if ( state == LOAD_DONE ) begin
                // No longer accepting inputs
                AXIS_TREADY = 0;

                // Done loading inputs, so generate inputs_loaded value
                inputs_loaded = 1;
                
                // Reset x and w counters to prepare for next matrix
                rst_x_ctr = 1;
                rst_w_ctr = 1;
            end
        end


        always_comb begin : next_state_logic
            // Initial state (reset). Wait for valid data to start processing
            if ( state == WAIT_FOR_READY ) begin
                if ( AXIS_TVALID == 1 && AXIS_TREADY == 1 ) begin
                    if ( new_W == 1 ) next_state = LOAD_W_MATRIX;
                    else next_state = LOAD_X_MATRIX;
                end
                else next_state = WAIT_FOR_READY;
            end
            else if ( state == LOAD_W_MATRIX ) begin
                // Check if this is the last write for W memory (assuming valid write on this clock cycle for W)
                // If it is, go to next state of load_B_val, otherwise stay in same stat
                if ( W_write_addr == last_w_idx && AXIS_TVALID == 1'b1 ) next_state = LOAD_B_VAL;
                else next_state = LOAD_W_MATRIX;
            end
            else if ( state == LOAD_B_VAL ) begin
                // Only jump to next state if TVALID is a 1 (we will load the b value)
                if ( AXIS_TVALID == 1'b1 ) begin
                    next_state = LOAD_X_MATRIX;
                end
                else begin
                    next_state = LOAD_B_VAL;
                end
            end
            else if ( state == LOAD_X_MATRIX ) begin
                // If R = 3, C = 2, then last index is 
                // 3 * 2 - 1 = 5 (where X_ADDR_SIZE = R * C) (and assuming that we have a write on this clock cycle)
                // In that case, we are done loading the matrix
                if ( X_write_addr == X_ADDR_SIZE - 1 && AXIS_TVALID == 1'b1 ) next_state = LOAD_DONE;
                // Otherwise, stay in the same state (continue loading the X matrix)
                else next_state = LOAD_X_MATRIX;
            end
            else if ( state == LOAD_DONE ) begin
                // If we're finished processing the matrices, we can continue the process again
                if ( compute_finished == 1 ) next_state = WAIT_FOR_READY;
                // Otherwise, stay in this state and wait for finished result
                else next_state = LOAD_DONE;
            end
            // Default case so we don't get inferred latch (combinational logic)
            else next_state = WAIT_FOR_READY; 
        end

    // =========================== Control Logic End ===========================

endmodule