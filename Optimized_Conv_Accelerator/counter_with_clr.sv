/*
 * Description: Counter with synchronous reset, clear, and inc signal
 * Clear has precedence over incr
*/
module counter_with_clr #(
        parameter OUTW = 16
    )(
        input clk,
        input reset,
        input clr,
        input incr,
        output logic [ OUTW - 1 : 0 ] out
    );

    always_ff @(posedge clk) begin
        if(reset == 1'b1) out <= 0;
        else if (clr == 1'b1) out <= 0;
        else if(incr) out <= out + 1;
    end

endmodule