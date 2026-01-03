module mux_2_1 #(
        parameter DATA_WIDTH = 32
    )(
        input [DATA_WIDTH - 1 : 0 ] in0,
        input [DATA_WIDTH - 1 : 0 ] in1,
        input sel,
        output logic [ DATA_WIDTH - 1 : 0] out
    );

    assign out = ( sel == 0 ) ? in0 : in1;

endmodule