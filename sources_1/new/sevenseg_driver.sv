module sevenseg_driver (
    input  logic        clk,
    input  logic [15:0] value,      // 4 hex digits
    input  logic        dp_3,       // leftmost DP
    input  logic        dp_2,
    input  logic        dp_1, 
    input  logic        dp_0,       // rightmost DP
    input  logic        reset,
    output logic [3:0]  an,         // anode controls (AN3, AN2, AN1, AN0)
    output logic [6:0]  seg,        // segment controls (a, b, c, d, e, f, g)
    output logic        dp          // decimal point control
);

    // Hex digit to 7-segment patterns (active low)
    localparam logic [6:0] SEG_PATTERNS [16] = '{
        7'b1000000,  // 0
        7'b1111001,  // 1
        7'b0100100,  // 2
        7'b0110000,  // 3
        7'b0011001,  // 4
        7'b0010010,  // 5
        7'b0000010,  // 6
        7'b1111000,  // 7
        7'b0000000,  // 8
        7'b0010000,  // 9
        7'b0001000,  // A
        7'b0000011,  // B
        7'b1000110,  // C
        7'b0100001,  // D
        7'b0000110,  // E
        7'b0001110   // F
    };
    
    // Multiplex counter (16-bit for ~1.5kHz per digit refresh rate)
    logic [15:0] refresh_counter;
    
    // Current digit being displayed (2-bit counter)
    logic [1:0] digit_select;
    
    // Individual hex digits extracted from value
    logic [3:0] digit_3, digit_2, digit_1, digit_0;
    logic [3:0] current_digit;
    logic current_dp;
    
    // Extract individual digits
    assign digit_3 = value[15:12];  // leftmost digit
    assign digit_2 = value[11:8];
    assign digit_1 = value[7:4];
    assign digit_0 = value[3:0];    // rightmost digit
    
    // Refresh counter and digit select
    always_ff @(posedge clk) begin
        if (reset) begin
            refresh_counter <= 16'd0;
            digit_select <= 2'd0;
        end else begin
            refresh_counter <= refresh_counter + 1;
            // Update digit select on counter overflow (every 65536 cycles)
            if (refresh_counter == 16'hFFFF) begin
                digit_select <= digit_select + 1;
            end
        end
    end
    
    // Multiplex current digit and decimal point
    always_comb begin
        unique case (digit_select)
            2'd0: begin
                current_digit = digit_0;
                current_dp = dp_0;
            end
            2'd1: begin
                current_digit = digit_1;
                current_dp = dp_1;
            end
            2'd2: begin
                current_digit = digit_2;
                current_dp = dp_2;
            end
            2'd3: begin
                current_digit = digit_3;
                current_dp = dp_3;
            end
        endcase
    end
    
    // Generate outputs
    always_comb begin
        if (reset) begin
            // All segments dark during reset
            an = 4'b1111;       // No digits selected (active low)
            seg = 7'b1111111;   // All segments off (active low)
            dp = 1'b1;          // Decimal point off (active low)
        end else begin
            // Normal operation
            unique case (digit_select)
                2'd0: an = 4'b1110;  // Select AN0 (rightmost)
                2'd1: an = 4'b1101;  // Select AN1
                2'd2: an = 4'b1011;  // Select AN2
                2'd3: an = 4'b0111;  // Select AN3 (leftmost)
            endcase
            
            seg = SEG_PATTERNS[current_digit];
            dp = ~current_dp;  // Invert because DP is active low
        end
    end

endmodule
