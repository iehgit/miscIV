module simple_io_device (
    input  logic        clk,
    input  logic        reset,
    
    // I/O Controller Interface
    input  logic        device_select,     // Device selected by I/O controller
    input  logic [3:0]  register_offset,   // Register within device
    input  logic        read_req,          // Read request
    input  logic        write_req,         // Write request
    input  logic [15:0] wdata,             // Write data
    output logic [15:0] rdata,             // Read data
    
    // External I/O connections
    input  logic [15:0] switches,          // Switch inputs
    output logic [15:0] leds               // LED outputs
);

    // Simple I/O device register offsets (within Device 2047: 0xFFF0-0xFFFF)
    // Filling from top down
    // 0xFFF0-0xFFFB: Reserved for future simple devices
    localparam logic [3:0] CYCLE_CTR_OFFSET   = 4'hC;  // 0xFFFC: Cycle counter
    localparam logic [3:0] SECONDS_CTR_OFFSET = 4'hD;  // 0xFFFD: Seconds counter
    localparam logic [3:0] SWITCH_OFFSET      = 4'hE;  // 0xFFFE: Switches
    localparam logic [3:0] LED_OFFSET         = 4'hF;  // 0xFFFF: LEDs
    
    // Simple I/O device storage
    logic [15:0] led_reg;             // LED register
    logic [15:0] seconds_counter;     // Seconds counter (increments every ~second)
    logic [15:0] cycle_counter;       // Cycle counter (increments every cycle)
    
    // 1Hz generation using cascaded dividers
    logic second_tick;         // 1-cycle pulse every ~second (1.00123Hz)
    logic second_tick_reset;    // Reset signal for pulse generator
    
    pulse_generator pulse_generator (
        .clk(clk),
        .reset(reset || second_tick_reset),
        .pulse_out(second_tick)
    );
    
    // Simple I/O device operations
    always_ff @(posedge clk) begin
        if (reset) begin
            led_reg <= 16'h0000;           // All LEDs off on reset
            seconds_counter <= 16'h0000;   // Seconds counter starts at 0
            cycle_counter <= 16'h0000;     // Cycle counter starts at 0
        end else begin
            // Always increment cycle counter (continuous operation)
            cycle_counter <= cycle_counter + 1;
            
            second_tick_reset <= 1'b0;  // Default: no reset
            
            // Seconds counter: increment on tick
            if (second_tick) begin
                seconds_counter <= seconds_counter + 1;
            end
            
            // Write to Simple I/O device registers
            if (write_req && device_select) begin
                unique case (register_offset)
                    LED_OFFSET: begin
                        led_reg <= wdata;  // Write to LED register
                    end
                    SECONDS_CTR_OFFSET: begin
                        seconds_counter <= wdata;
                        second_tick_reset <= 1'b1;  // Reset the pulse generator
                    end
                    CYCLE_CTR_OFFSET: begin
                        cycle_counter <= wdata;      // Set cycle counter value
                    end
                    default: begin
                        // Ignore writes to unimplemented/reserved registers
                    end
                endcase
            end
        end
    end
    
    // Register read multiplexer
    always_comb begin
        rdata = 16'hXXXX;
        if (read_req && device_select) begin
            unique case (register_offset)
                SECONDS_CTR_OFFSET: rdata = seconds_counter; // Read seconds counter
                CYCLE_CTR_OFFSET:   rdata = cycle_counter;   // Read cycle counter
                LED_OFFSET:         rdata = led_reg;         // Read LED register
                SWITCH_OFFSET:      rdata = switches;        // Read switches
                default:            rdata = 16'hFFFF;        // Unimplemented simple registers (bus pull-ups)
            endcase
        end
    end
    
    // LED output assignment
    assign leds = led_reg;

endmodule
