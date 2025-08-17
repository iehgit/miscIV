module debouncer_long (
    input  logic clk,
    input  logic btn_in,
    output logic pulse_out,      // Short press pulse (after 5.24ms)
    output logic long_pulse_out  // Long press pulse (after 1.342s)
);

    // Synchronizer registers to avoid metastability
    logic btn_sync1, btn_sync2;
    
    // Counter for timing (27-bit for long press detection)
    logic [26:0] counter;
    
    // Thresholds
    localparam DEBOUNCE_THRESHOLD = 27'h7FFFF;      // 2^19-1 = 524,287 cycles (~5.24ms)
    localparam LONG_PRESS_THRESHOLD = 27'h7FFFFFF;  // 2^27-1 = 134,217,727 cycles (~1.342s)
    
    // Synchronize the button input to avoid metastability
    always_ff @(posedge clk) begin
        btn_sync1 <= btn_in;
        btn_sync2 <= btn_sync1;
    end
    
    // Counter logic
    always_ff @(posedge clk) begin
        if (btn_sync2) begin
            // Button is pressed - count up
            if (counter < LONG_PRESS_THRESHOLD) begin
                counter <= counter + 1;
            end
        end else begin
            // Button is released - reset counter
            counter <= 27'd0;
        end
    end
    
    // Generate output pulses
    always_ff @(posedge clk) begin
        // Short press pulse when counter reaches debounce threshold
        pulse_out <= (counter == DEBOUNCE_THRESHOLD);
        
        // Long press pulse when counter reaches long press threshold
        long_pulse_out <= (counter == LONG_PRESS_THRESHOLD);
    end

endmodule
