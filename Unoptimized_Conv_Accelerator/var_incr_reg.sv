module var_incr_reg #(
        parameter MAX_INCR_BITS = 8,
        parameter OUTW = 16
    )(
        input [ MAX_INCR_BITS - 1 : 0 ] incr_amt,
        input incr,
        input clr,
        input clk,
        input reset,
        output logic [ OUTW - 1 : 0 ] out
    );

    always_ff @ ( posedge clk ) begin
        if ( reset == 1 ) out <= 0; // reset if reset asserted 
        else if ( clr == 1 ) out <= 0; //clear if clr asserted
        else if ( incr == 1 ) out <= out + incr_amt; // increment by incr_amt if incr asserted
    end


endmodule