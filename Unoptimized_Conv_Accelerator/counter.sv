module counter #(
        parameter OUT_WIDTH = 16
    )(
        input clk,
        input reset,
        input incr,
        output logic [ OUT_WIDTH - 1 : 0 ] out
    );

    always_ff @(posedge clk) begin
        if(reset == 1'b1) out <= 0;
        else if(incr) out <= out + 1;
    end

endmodule