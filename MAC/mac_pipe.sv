// module mac_pipe #(
//     parameter INW = 24,
//     parameter OUTW = 48
// )(
//     input signed [INW-1:0]          input0, input1, init_value,
//     output logic signed [OUTW-1:0]  out,
//     input                           clk, reset, init_acc, input_valid
// );

//     logic signed [2*INW-1:0] mult;
//     logic signed [OUTW-1:0] acc;
//     logic input_valid_reg; //output input_valid signal from pipeline register
//     logic signed [2*INW-1:0] mult_comb;
    
//     assign mult_comb = input0 * input1; //combinational multiplier

//     always_ff @(posedge clk) begin
//         mult <= mult_comb; //assign mult reg signal to input0 * input1 (done combinationally)
// 	    input_valid_reg <= input_valid; //pipelined valid_reg signal
//     end

//     assign acc = mult + out;

//     always_ff @(posedge clk) begin
// 	    if(reset) out <= 0; //synchronous reset
//         else if(init_acc) out <= init_value; //check if init_acc is set, and load the init_value to it
//         else if(input_valid_reg) out <= acc; //use pipelined valid_reg signal
//     end
    

// endmodule
