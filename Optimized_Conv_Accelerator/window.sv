module window #(
        parameter INW = 16,
        parameter C = 4,
        parameter MAXK = 3,
        localparam K_SIZE = $clog2(MAXK+1),
        localparam ROW_LOAD_SIZE = $clog2(MAXK+1), //up to MAXK value (we need 1 extra row)
        localparam COL_LOAD_SIZE = $clog2(C) //up to C-1 value
    )(
        input [INW - 1 : 0] pixel_in,
        input [K_SIZE - 1 : 0] K,
        input pixel_valid, 
        input clk,
        input reset,
        input clr,
        input init_true,
        output logic [INW - 1 : 0] window_out [MAXK - 1 : 0][MAXK - 1 : 0]
    );

    logic [INW - 1 : 0] line_buffer [MAXK - 1 : 0][C - 1 : 0]; //line buffer has MAXK rows and C columns

    logic [ROW_LOAD_SIZE - 1 : 0] row_count;
    logic [COL_LOAD_SIZE - 1 : 0] col_count;
    logic window_valid;
    
    always_ff @ (posedge clk) begin
        if (reset || clr) begin //system reset or separate clr asserted
            row_count <= 0;
            col_count <= 0;
        end
        else if (pixel_valid || (init_true && !window_valid)) begin //it's a valid pixel or we're loading from AXI-Stream interface (init_true and we haven't reached the end of the buffer to immediately
                                                                    //compute the first convolution (indicated by !window_valid))
            line_buffer[0][0] <= pixel_in; //store newest pixel in first index of line buffer
            for(int c = 1; c < C; c=c+1) line_buffer[0][c] <= line_buffer[0][c-1]; //shift line buffer 0 (special case
                                                                                //because lilne buffer[0][0] gets inp data)
            for(int r = 1; r < MAXK; r=r+1) begin //iterate over the rows (not including 0)
                for(int c = 1; c < C; c=c+1) begin //iterate over the columns (not including 0)
                    line_buffer[r][c] <= line_buffer[r][c-1]; //shift data down line buffer
                end
                line_buffer[r][0] <= line_buffer[r-1][C-1]; //shift end of line data to next line buffer line
            end
            if (col_count == C - 1) begin
                col_count <= 0; //reset column counter to point to latest data
                if(row_count != K-1) begin
                    row_count <= row_count + 1; //only increment the row count if we haven't reached K - 1 yet (used for indicating valid data)
                end
            end
            else begin //col_count != C - 1
                col_count <= col_count + 1; //increment it
            end
        end
    end

    always_comb begin : window_with_masking
        for(int r = 0; r < MAXK; r=r+1) begin
            for(int c = 0; c < MAXK; c=c+1) begin
                if(r < K && c < K) begin
                    window_out[r][c] = line_buffer[K - 1 - r][K - 1 - c]; //Oldest data is at last index
                                                                        //Indicated by line_buffer[K -1][K-1]
                                                                        //subtract r and c to get the next K -1 values
                end
                else begin
                    window_out[r][c] = 0; //set window_out to 0 for other values (not valid data)
                end
            end
        end
    end

assign window_valid = (row_count == K-1) && (col_count > K - 1); //row_count == K - 1, and col_count >= K - 1 (indicating we've incremented the counter enough
                                                                    //to read new row, but might want to debug this)
                                                                    //This condition is helpful for my particular system
                                                                    //which allows me to pre-fetch the weights

endmodule