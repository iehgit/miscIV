// =============================================================================
// ASCII Translator Module
// =============================================================================
// Converts PS/2 scan codes to 7-bit ASCII characters.
// 
// Features:
// - Translates keys that have ASCII representations (letters, digits, symbols)
// - Tracks shift key state for uppercase letters and shifted symbols  
// - Handles break codes (0xF0) to detect key releases
// - Ignores extended codes (0xE0) as they represent non-ASCII keys
// - Outputs ASCII only on key press events, not releases
//
// Note: Output is registered, adding one cycle latency from scan_valid to ascii_valid
// =============================================================================

module ascii_translator (
    input  logic        clk,
    input  logic        reset,
    
    // From keyboard controller frame decoder
    input  logic [7:0]  scan_code,      // Raw scan code
    input  logic        scan_valid,     // New scan code available (pulse)
    
    // ASCII output
    output logic [6:0]  ascii_code,     // 7-bit ASCII
    output logic        ascii_valid     // Valid ASCII character ready (pulse)
);

    // PS/2 Set 2 scan codes for special handling
    localparam logic [7:0] SCAN_BREAK     = 8'hF0;  // Break code prefix
    localparam logic [7:0] SCAN_EXTENDED  = 8'hE0;  // Extended code prefix (non-ASCII keys)
    localparam logic [7:0] SCAN_LSHIFT    = 8'h12;  // Left shift
    localparam logic [7:0] SCAN_RSHIFT    = 8'h59;  // Right shift
    
    // State machine for scan code processing
    typedef enum logic [1:0] {
        STATE_NORMAL,       // Normal scan codes
        STATE_BREAK,        // Next code is a break (key release)
        STATE_EXTENDED      // Extended code sequence (no ASCII translation possible)
    } translator_state_t;
    
    translator_state_t state, next_state;
    
    // Shift key tracking
    logic left_shift_down, right_shift_down;
    logic next_left_shift_down, next_right_shift_down;
    logic shift_state;  // Internal shift state
    
    // ASCII lookup signals
    logic [6:0] ascii_normal, ascii_shifted;
    logic [6:0] ascii_output;
    logic       generate_ascii;
    
    // Internal shift state (for selecting shifted ASCII)
    assign shift_state = left_shift_down || right_shift_down;
    
    // Instantiate ASCII lookup ROM
    ascii_lookup_rom lookup_rom (
        .scan_code(scan_code),
        .ascii_normal(ascii_normal),
        .ascii_shifted(ascii_shifted)
    );
    
    //=========================================================================
    // State Machine
    //=========================================================================
    
    // State register
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= STATE_NORMAL;
            left_shift_down <= 1'b0;
            right_shift_down <= 1'b0;
        end else begin
            state <= next_state;
            left_shift_down <= next_left_shift_down;
            right_shift_down <= next_right_shift_down;
        end
    end
    
    // Next state and output logic
    always_comb begin
        // Defaults
        next_state = state;
        next_left_shift_down = left_shift_down;
        next_right_shift_down = right_shift_down;
        generate_ascii = 1'b0;
        ascii_output = 7'h00;
        
        if (scan_valid) begin
            case (state)
                STATE_NORMAL: begin
                    case (scan_code)
                        SCAN_BREAK: begin
                            // Next scan code will be a break (key release)
                            next_state = STATE_BREAK;
                        end
                        
                        SCAN_EXTENDED: begin
                            // Extended code sequence for non-ASCII keys
                            // (arrow keys, navigation keys, etc.)
                            // These have no ASCII representation
                            next_state = STATE_EXTENDED;
                        end
                        
                        SCAN_LSHIFT: begin
                            // Left shift pressed
                            next_left_shift_down = 1'b1;
                        end
                        
                        SCAN_RSHIFT: begin
                            // Right shift pressed
                            next_right_shift_down = 1'b1;
                        end
                        
                        default: begin
                            // Regular key press - generate ASCII if available
                            if (shift_state) begin
                                ascii_output = ascii_shifted;
                            end else begin
                                ascii_output = ascii_normal;
                            end
                            // Only generate ASCII if lookup returned non-zero
                            generate_ascii = (ascii_output != 7'h00);
                        end
                    endcase
                end
                
                STATE_BREAK: begin
                    // This is a break code (key release)
                    next_state = STATE_NORMAL;
                    
                    // Check if it's a shift key release
                    case (scan_code)
                        SCAN_LSHIFT: begin
                            next_left_shift_down = 1'b0;
                        end
                        
                        SCAN_RSHIFT: begin
                            next_right_shift_down = 1'b0;
                        end
                        
                        default: begin
                            // Other key releases - no ASCII generation
                        end
                    endcase
                end
                
                STATE_EXTENDED: begin
                    // Extended codes are for non-ASCII keys (arrows, navigation, etc.)
                    // Simply consume the scan code and return to normal state
                    next_state = STATE_NORMAL;
                end
                
                default: begin
                    next_state = STATE_NORMAL;
                end
            endcase
        end
    end
    
    //=========================================================================
    // Output Generation
    //=========================================================================
    
    // Generate ASCII output and valid pulse
    always_ff @(posedge clk) begin
        if (reset) begin
            ascii_code <= 7'h00;
            ascii_valid <= 1'b0;
        end else begin
            if (generate_ascii) begin
                ascii_code <= ascii_output;
                ascii_valid <= 1'b1;
            end else begin
                ascii_valid <= 1'b0;
            end
        end
    end

endmodule
