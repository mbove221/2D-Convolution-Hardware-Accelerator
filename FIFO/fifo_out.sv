module fifo_out #(
        parameter OUTW = 24,
        parameter DEPTH = 38,
        localparam LOGDEPTH = $clog2(DEPTH)
    )(
        input clk,
        input reset,
        input [OUTW-1:0] IN_AXIS_TDATA,
        input IN_AXIS_TVALID,
        output logic IN_AXIS_TREADY,
        output logic [OUTW-1:0] OUT_AXIS_TDATA,
        output logic OUT_AXIS_TVALID,
        input OUT_AXIS_TREADY
);

    logic [ LOGDEPTH - 1 : 0 ] wr_addr; // Write address specified from head logic
    logic [ LOGDEPTH - 1 : 0 ] rd_addr;
    logic wr_en; // Inernal write enable for determining if we want to write data
    logic rd_en; // Internal read enable for determining if we want to read data

    logic [ LOGDEPTH - 1 : 0 ] tail; // Output of tail logic

    logic [ LOGDEPTH : 0 ] capacity; // $clog2(DEPTH) + 1 bits wide to account for DEPTH (2^LOGDEPTH) possible capacities 

    // Dual port memory instantiation
    memory_dual_port #(
            .WIDTH(OUTW), 
            .SIZE(DEPTH)
            ) 
        fifo_memory(
            .data_in(IN_AXIS_TDATA),
            .data_out(OUT_AXIS_TDATA),
            .write_addr(wr_addr),
            .read_addr(rd_addr),
            .clk(clk),
            .wr_en(wr_en)
        );

    // IN_AXIS_TREADY output logic
    // If FIFO is full and read enable is 0, output 0, otherwise output 1
    assign IN_AXIS_TREADY = (capacity == 0 && rd_en == 0) ? 0 : 1;

    // Internal wr_en logic for writing data if valid and ready (on next clock edge)
    assign wr_en = ( IN_AXIS_TVALID && IN_AXIS_TREADY );
    
    // OUT_AXIS_TVALID is asserted if FIFO isn't empty
    assign OUT_AXIS_TVALID = (capacity == DEPTH) ? 0 : 1;

    // Internal rd_en logic for reading data based on if valid and ready
    assign rd_en = ( OUT_AXIS_TVALID && OUT_AXIS_TREADY );

    // ======= Head logic begin =======
    always_ff @(posedge clk) begin : head_logic
        if( reset ) 
            /* Perform at reset */
            wr_addr <= 0;
        else if( wr_en == 1 ) begin
            /* Head logic to roll-over if DEPTH is not power of 2 (works same if it is) */
            if ( wr_addr == DEPTH - 1 )
                wr_addr <=  0;
            else
                wr_addr <= wr_addr + 1; 
        end
    end

    // ======= Head logic end =======

    // ======= Tail logic begin =======

    // Sequential tail logic to increment tail
    always_ff @ ( posedge clk ) begin : tail_logic_seq
        if ( reset )
            tail <= 0;
        // Check if rd_en is set
        else if ( rd_en == 1 ) begin
            // If tail is max value, roll over to 0
            if ( tail == DEPTH  - 1 )
                tail <= 0;
            // Otherwise, just increment tail pointer
            else
                tail <= tail + 1;
        end
    end

    // Combinational logic to check if rd_en is asserted for data on next positive clock edge
    always_comb begin : tail_logic_comb
        if ( rd_en == 0 )
            rd_addr = tail;
        else begin
            // Prepare next data (increment tail)
            // Necessary to see if we need to roll over, since rd_addr prepares next data
            if ( tail == DEPTH - 1 )
                rd_addr = 0;
            // Otherwise, just set rd_addr = tail + 1 
            else
                rd_addr = tail + 1;
        end
    end

    // ======= Tail logic end =======

    // ======= Capacity logic begin =======

    always_ff @ ( posedge clk ) begin
        if ( reset == 1 )
            capacity <= DEPTH; //If resetting system, initialize capacity to size of FIFO
        else begin 
            case ({rd_en, wr_en})
                2'b10: begin
                        capacity <= capacity + 1; // If rd but no write, increment capacity
                end
                2'b01: begin
                        capacity <= capacity - 1; // If write, but no read, decrease capacity
                end
                // Otherwise, if no read and no write or both read and write, do nothing
            endcase
        end
    end

    // ======= Capacity logic end =======

endmodule   