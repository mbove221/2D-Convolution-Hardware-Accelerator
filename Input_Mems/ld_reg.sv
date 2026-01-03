/*
 * D-type register with synchronous reset and load enable signal
*/
module ld_reg #(
    parameter WIDTH = 24
)(
    input [ WIDTH  - 1 : 0 ] in,
    input reset,
    input clk,
    input ld,
    output logic [ WIDTH - 1 : 0 ] out
);
    always_ff @(posedge clk) begin
        if ( reset == 1'b1 ) out <= 0;
        else if ( ld == 1'b1 ) out <= in;
    end

endmodule