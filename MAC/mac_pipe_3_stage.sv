module mac_pipe #(
    parameter INW = 16,
    parameter OUTW = 64,
    parameter PIPELINE_DEPTH = 5,
    localparam MULT_PIPE_DEPTH = PIPELINE_DEPTH - 2
)(
    input signed [INW-1:0]          input0, input1, init_value,
    output logic signed [OUTW-1:0]  out,
    input                           clk, reset, init_acc, input_valid
);

    logic signed [ INW - 1 : 0 ] inp0_buff;

    logic signed [ INW - 1 : 0 ] inp1_buff;

    logic signed [ INW - 1 : 0 ] init_value_PIPE [ MULT_PIPE_DEPTH ];

    logic init_acc_PIPE [ MULT_PIPE_DEPTH ];

    logic input_valid_PIPE [ MULT_PIPE_DEPTH ];

    logic signed [OUTW-1:0] acc;

    logic input_valid_reg; //output input_valid signal from pipeline register

    logic signed [2*INW-1:0] mult;

    logic signed [2*INW-1:0] mult_out;

    int i;
    
    DW02_mult_3_stage #(
        .A_width(INW), 
        .B_width(INW)
    ) multiplier_3_stage(
        .A(inp0_buff),
        .B(inp1_buff),
        .TC(1'b1),
        .CLK(clk),
        .PRODUCT(mult_out)
    );

    always_ff @(posedge clk) begin
        inp0_buff <= input0;
        inp1_buff <= input1;

        init_value_PIPE[0] <= init_value;
        init_acc_PIPE[0] <= init_acc;
        input_valid_PIPE[0] <= input_valid;

        for ( i = 1; i < MULT_PIPE_DEPTH; i = i + 1 ) begin
            if ( reset ) begin
                init_value_PIPE[i] <= 0;
                init_acc_PIPE[i] <= 0;
                input_valid_PIPE[i] <= 0;
            end 
            else begin
                init_value_PIPE[i] <= init_value_PIPE[i-1];
                init_acc_PIPE[i] <= init_acc_PIPE[i-1];
                input_valid_PIPE[i] <= input_valid_PIPE[i-1];
            end
        end
    end

    always_ff @(posedge clk) begin
        if ( reset ) input_valid_reg <= 0;
        else input_valid_reg <= input_valid_PIPE [ MULT_PIPE_DEPTH - 1 ]; //pipelined valid_reg signal
        mult <= mult_out; //assign mult reg signal to input0 * input1 (done combinationally)
    end

    assign acc = mult + out;

    always_ff @(posedge clk) begin
	    if(reset) out <= 0; //synchronous reset
        else if(init_acc_PIPE[MULT_PIPE_DEPTH - 1]) out <= init_value_PIPE[MULT_PIPE_DEPTH - 1]; //check if init_acc is set, and load the init_value to it
        else if(input_valid_reg) out <= acc; //use pipelined valid_reg signal
    end
    

endmodule
