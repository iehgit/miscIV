module debouncer (
    input  logic clk,
    input  logic btn_in,
    output logic pulse_out
);

    // Synchronizer registers to avoid metastability
    logic btn_sync1, btn_sync2;
    
    // Counter for debounce timing (19-bit for 2^19-1 = 524,287 cycles = 5.24ms)
    logic [18:0] counter;
    
    // Synchronize the button input to avoid metastability
    always_ff @(posedge clk) begin
        btn_sync1 <= btn_in;
        btn_sync2 <= btn_sync1;
    end
    
    // Counter logic
    always_ff @(posedge clk) begin
        if (btn_sync2) begin
            // Button is pressed - count up
            if (counter < 19'h7FFFF) begin
                counter <= counter + 1;
            end
        end else begin
            // Button is released - reset counter
            counter <= 19'd0;
        end
    end
    
    // Generate rising edge pulse after debounce
    always_ff @(posedge clk) begin
        pulse_out <= (counter == 19'h7FFFF);  // Pulse when reaching threshold
    end

endmodule
