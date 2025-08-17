module pulse_generator (
    input  logic clk,
    input  logic reset,        // Optional reset (can tie to 0 if not needed)
    output logic pulse_out     // Single-cycle pulse at ~1Hz
);
    // Generates ~1.00123Hz (0.123% fast)
    // 100MHz / (262,144 * 381) = 1.00123Hz
    
    logic [17:0] div_first;    // 18 bits: rolls over naturally at 2^18 (262,144)
    logic [8:0]  div_second;   // 9 bits: counts 0 to 380 (381 total)
    
    always_ff @(posedge clk) begin
        pulse_out <= 1'b0;     // Default: no pulse
        
        if (reset) begin
            div_first <= 18'd0;
            div_second <= 9'd0;
        end else begin
            div_first <= div_first + 1;  // Always increment, rolls over naturally at 2^18
            
            // Check if div_first just rolled over to 0 (every 262,144 cycles)
            if (div_first == 18'd0) begin  
                if (div_second == 9'd380) begin  // 381 total counts (0-380)
                    div_second <= 9'd0;
                    pulse_out <= 1'b1;        // Generate ~1Hz pulse (1.00123Hz)
                end else begin
                    div_second <= div_second + 1;
                end
            end
        end
    end
    
endmodule