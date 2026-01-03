// module mac #(
//     parameter INW = 16,
//     parameter OUTW = 64
// )(
//     input signed [INW-1:0]          input0, input1, init_value,
//     output logic signed [OUTW-1:0]  out,
//     input                           clk, reset, init_acc, input_valid
// );

//     logic signed [2*INW-1:0] mult;
//     logic signed [OUTW-1:0] acc;

//     assign mult = input0 * input1; //combinational multiplier
 
//     assign acc = mult + out; //combinational adder

//     always_ff @(posedge clk) begin
// 	if(reset) out <= 0; //synchronous reset
//         else if(init_acc) out <= init_value; //initialize to init_value
//         else if(input_valid) out <= acc; //otherwise set output of reg to accumulator's value
//     end
    

// endmodule