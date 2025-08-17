module text_controller (
    input  logic        clk,
    input  logic        reset,
    
    // Memory-mapped register interface (text registers only: 0x0-0x2)
    input  logic        device_select,      // Pre-qualified for text registers
    input  logic [3:0]  register_offset,   
    input  logic        write_req,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,
    
    // Frame buffer interface (generic - main module handles A/B selection)
    output logic [13:0] fb_addr,
    output logic [7:0]  fb_data,
    output logic        fb_write_enable,
    input  logic [7:0]  fb_read_data,       // Multiplexed by main module
    
    // Clear operation interface
    output logic        clear_request,      // Request frame buffer clear
    input  logic        clear_in_progress,  // Main module performing clear
    
    // Status
    output logic        busy                // Text operations in progress
);

// Frame buffer parameters (same as main module)
localparam FRAME_WIDTH = 320;
localparam COLOR_CELLS_X = 40;

// Text register addresses (updated mapping)
localparam REG_CHAR_INPUT = 4'h0;
localparam REG_CHAR_COORDINATES = 4'h1;  // Combined X/Y
localparam REG_CHAR_CONTROL = 4'h2;      // Moved from 0x4

// Text registers
logic [15:0] char_input_reg;
logic [15:0] text_coordinates_reg;  // Combined: Y(12:8), X(5:0)

// Auto-cursor position registers (for FixPos=0)
logic [5:0] cursor_x;  // 0-39 (only 6 bits needed)
logic [4:0] cursor_y;  // 0-24 (only 5 bits needed)

// UNIFIED STATE MACHINE - handles both characters sequentially with Add mode support
typedef enum logic [5:0] {
    UNIFIED_IDLE,
    
    // First character processing
    FIRST_CHAR_SETUP,
    FIRST_CHAR_CALC_ADDR,
    FIRST_CHAR_FETCH_GLYPH,
    FIRST_CHAR_WAIT_GLYPH,
    FIRST_CHAR_WRITE_ROW0,
    FIRST_CHAR_WRITE_ROW1,
    FIRST_CHAR_WRITE_ROW2,
    FIRST_CHAR_WRITE_ROW3,
    FIRST_CHAR_WRITE_ROW4,
    FIRST_CHAR_WRITE_ROW5,
    FIRST_CHAR_WRITE_ROW6,
    FIRST_CHAR_WRITE_ROW7,
    FIRST_CHAR_CURSOR_UPDATE,
    
    // First character Add mode processing
    FIRST_CHAR_READ_ROW0,
    FIRST_CHAR_READ_ROW1,
    FIRST_CHAR_READ_ROW2,
    FIRST_CHAR_READ_ROW3,
    FIRST_CHAR_READ_ROW4,
    FIRST_CHAR_READ_ROW5,
    FIRST_CHAR_READ_ROW6,
    FIRST_CHAR_READ_ROW7,
    FIRST_CHAR_ADD_ROW0,
    FIRST_CHAR_ADD_ROW1,
    FIRST_CHAR_ADD_ROW2,
    FIRST_CHAR_ADD_ROW3,
    FIRST_CHAR_ADD_ROW4,
    FIRST_CHAR_ADD_ROW5,
    FIRST_CHAR_ADD_ROW6,
    FIRST_CHAR_ADD_ROW7,
    
    // Second character processing
    SECOND_CHAR_SETUP,
    SECOND_CHAR_CALC_ADDR,
    SECOND_CHAR_FETCH_GLYPH,
    SECOND_CHAR_WAIT_GLYPH,
    SECOND_CHAR_WRITE_ROW0,
    SECOND_CHAR_WRITE_ROW1,
    SECOND_CHAR_WRITE_ROW2,
    SECOND_CHAR_WRITE_ROW3,
    SECOND_CHAR_WRITE_ROW4,
    SECOND_CHAR_WRITE_ROW5,
    SECOND_CHAR_WRITE_ROW6,
    SECOND_CHAR_WRITE_ROW7,
    SECOND_CHAR_CURSOR_UPDATE,
    
    // Second character Add mode processing
    SECOND_CHAR_READ_ROW0,
    SECOND_CHAR_READ_ROW1,
    SECOND_CHAR_READ_ROW2,
    SECOND_CHAR_READ_ROW3,
    SECOND_CHAR_READ_ROW4,
    SECOND_CHAR_READ_ROW5,
    SECOND_CHAR_READ_ROW6,
    SECOND_CHAR_READ_ROW7,
    SECOND_CHAR_ADD_ROW0,
    SECOND_CHAR_ADD_ROW1,
    SECOND_CHAR_ADD_ROW2,
    SECOND_CHAR_ADD_ROW3,
    SECOND_CHAR_ADD_ROW4,
    SECOND_CHAR_ADD_ROW5,
    SECOND_CHAR_ADD_ROW6,
    SECOND_CHAR_ADD_ROW7
} unified_state_t;

unified_state_t unified_state;

// Character storage for processing
logic [6:0] first_char_stored, second_char_stored;
logic first_char_invert, second_char_invert;  // Store invert flags
logic second_char_valid;        // True if second character is not NUL or DEL
logic current_char_invert;      // Current character's invert flag
logic processing_fixpos_mode;   // Store FixPos mode for current operation
logic [5:0] processing_write_x; // Store write position for FixPos=1 mode
logic [4:0] processing_write_y;

// Add mode support
logic [7:0] read_row_data[8];   // Store read data for each row (0-7)
logic       char_add_mode;      // Store Add mode for current operation

// Text operation signals
logic [6:0] char_to_write;        // ASCII character being written
logic [5:0] char_write_x;         // Character X position (0-39)
logic [4:0] char_write_y;         // Character Y position (0-24)
logic [13:0] pixel_base_addr;     // Base address for pixel data

// Glyph processing signals
logic [6:0] glyph_char_code;
logic [63:0] glyph_data;

// Glyph row extraction function with inversion support
function automatic [7:0] extract_glyph_row(input [63:0] glyph_data, input [2:0] row_number, input invert);
    logic [7:0] raw_row_data;
    raw_row_data = glyph_data[63 - (row_number * 8) -: 8];
    extract_glyph_row = invert ? ~raw_row_data : raw_row_data;
endfunction

// Task for writing glyph row in normal mode
task write_glyph_row(input [2:0] row_num);
    fb_addr <= pixel_base_addr + row_num * COLOR_CELLS_X;
    fb_data <= extract_glyph_row(glyph_data, row_num, current_char_invert);
    fb_write_enable <= 1'b1;
endtask

// Task for writing glyph row in Add mode (OR with existing data)
task write_glyph_row_add(input [2:0] row_num);
    fb_addr <= pixel_base_addr + row_num * COLOR_CELLS_X;
    fb_data <= read_row_data[row_num] | extract_glyph_row(glyph_data, row_num, current_char_invert);
    fb_write_enable <= 1'b1;
endtask

// Font ROM
glyph_rom glyph_rom (
    .char_code(glyph_char_code),
    .glyph_data(glyph_data)
);

// Connect glyph ROM to current character being processed
assign glyph_char_code = char_to_write;

// Busy signal - true when any operation is in progress
assign busy = (unified_state != UNIFIED_IDLE);

// Clear request handling
logic clear_request_reg;
assign clear_request = clear_request_reg;

// Main sequential logic
always_ff @(posedge clk) begin
    if (reset) begin
        // Text registers
        char_input_reg <= 16'h0000;
        text_coordinates_reg <= 16'h0000;
        
        // Auto-cursor
        cursor_x <= 6'd0;
        cursor_y <= 5'd0;
        
        // Character storage
        first_char_stored <= 7'h00;
        second_char_stored <= 7'h00;
        first_char_invert <= 1'b0;
        second_char_invert <= 1'b0;
        second_char_valid <= 1'b0;
        current_char_invert <= 1'b0;
        processing_fixpos_mode <= 1'b0;
        processing_write_x <= 6'd0;
        processing_write_y <= 5'd0;
        
        // Add mode support
        for (int i = 0; i < 8; i++) begin
            read_row_data[i] <= 8'h00;
        end
        char_add_mode <= 1'b0;
        
        // Unified state machine
        unified_state <= UNIFIED_IDLE;
        char_to_write <= 7'h20;  // Default to space
        char_write_x <= 6'd0;
        char_write_y <= 5'd0;
        pixel_base_addr <= 14'd0;
        
        // Frame buffer interface
        fb_addr <= 14'd0;
        fb_data <= 8'h00;
        fb_write_enable <= 1'b0;
        
        // Clear request
        clear_request_reg <= 1'b0;
    end else begin
        // Clear single-cycle signals
        fb_write_enable <= 1'b0;
        clear_request_reg <= 1'b0;  // Clear request is single-cycle pulse
        
        // Reset cursor when clear operation completes
        if (clear_in_progress && unified_state == UNIFIED_IDLE) begin
            cursor_x <= 6'd0;
            cursor_y <= 5'd0;
        end
        
        // Unified state machine - handles both characters sequentially
        if (unified_state != UNIFIED_IDLE) begin
            case (unified_state)
                // FIRST CHARACTER PROCESSING
                FIRST_CHAR_SETUP: begin
                    current_char_invert <= first_char_invert;  // Set invert flag for first char
                    
                    if (processing_fixpos_mode) begin
                        // FixPos=1: Use explicit coordinates
                        char_write_x <= processing_write_x;
                        char_write_y <= processing_write_y;
                    end else begin
                        // FixPos=0: Use current cursor position
                        char_write_x <= cursor_x;
                        char_write_y <= cursor_y;
                    end
                    
                    // Handle special characters
                    if (processing_fixpos_mode && (first_char_stored == 7'h0A || first_char_stored == 7'h0B || 
                        first_char_stored == 7'h0C || first_char_stored == 7'h0D)) begin
                        // FixPos=1: Skip cursor movement in setup, let CURSOR_UPDATE handle it
                        unified_state <= FIRST_CHAR_CURSOR_UPDATE;
                    end else if (first_char_stored == 7'h08) begin  // BS (Backspace)
                        // Pre-move cursor for backspace
                        if (cursor_x == 0) begin
                            char_write_x <= 6'd39;
                            char_write_y <= (cursor_y == 0) ? 5'd24 : cursor_y - 1;
                            cursor_x <= 6'd39;
                            cursor_y <= (cursor_y == 0) ? 5'd24 : cursor_y - 1;
                        end else begin
                            char_write_x <= cursor_x - 1;
                            char_write_y <= cursor_y;
                            cursor_x <= cursor_x - 1;
                        end
                        char_to_write <= 7'h20;  // Write space
                        unified_state <= FIRST_CHAR_CALC_ADDR;
                    end else if (first_char_stored == 7'h0A) begin  // LF
                        // Line feed - just move cursor
                        cursor_x <= 6'd0;
                        cursor_y <= (cursor_y == 24) ? 5'd0 : cursor_y + 1;
                        unified_state <= FIRST_CHAR_CURSOR_UPDATE;  // Skip to cursor update
                    end else if (first_char_stored == 7'h0B) begin  // VT (Vertical Tab)
                        // Vertical tab - move cursor row+1 and col+1
                        if (cursor_x == 39) begin
                            // X wraps, Y increments by 2 (1 for VT, 1 for wrap)
                            cursor_x <= 6'd0;
                            cursor_y <= (cursor_y >= 23) ? 5'd0 : cursor_y + 2;
                        end else begin
                            // Normal VT movement
                            cursor_x <= cursor_x + 1;
                            cursor_y <= (cursor_y == 24) ? 5'd0 : cursor_y + 1;
                        end
                        unified_state <= FIRST_CHAR_CURSOR_UPDATE;  // Skip to cursor update
                    end else if (first_char_stored == 7'h0C) begin  // FF
                        // Form feed - move cursor to home
                        cursor_x <= 6'd0;
                        cursor_y <= 5'd0;
                        unified_state <= FIRST_CHAR_CURSOR_UPDATE;  // Skip to cursor update
                    end else if (first_char_stored == 7'h0D) begin  // CR
                        // Carriage return - move cursor to start of line
                        cursor_x <= 6'd0;
                        unified_state <= FIRST_CHAR_CURSOR_UPDATE;  // Skip to cursor update
                    end else if (first_char_stored == 7'h00 || first_char_stored == 7'h7F) begin  // NUL or DEL
                        // NUL/DEL - no action, skip to cursor update
                        unified_state <= FIRST_CHAR_CURSOR_UPDATE;
                    end else begin
                        // Normal character - write it
                        if (first_char_stored == 7'h09) begin
                            char_to_write <= 7'h20;  // Tab becomes space
                        end else begin
                            char_to_write <= first_char_stored;
                        end
                        unified_state <= FIRST_CHAR_CALC_ADDR;
                    end
                end
                
                FIRST_CHAR_CALC_ADDR: begin
                    // Calculate base addresses for pixel data
                    pixel_base_addr <= (char_write_y * 16'd8 * FRAME_WIDTH + char_write_x * 16'd8) >> 3;  // Byte address (divide by 8)
                    unified_state <= FIRST_CHAR_FETCH_GLYPH;
                end
                
                FIRST_CHAR_FETCH_GLYPH: begin
                    // Glyph ROM read is combinational, but we wait one cycle for clarity
                    unified_state <= FIRST_CHAR_WAIT_GLYPH;
                end
                
                FIRST_CHAR_WAIT_GLYPH: begin
                    // Glyph data is now available
                    if (char_add_mode) begin
                        unified_state <= FIRST_CHAR_READ_ROW0;  // Add mode path
                    end else begin
                        unified_state <= FIRST_CHAR_WRITE_ROW0; // Normal mode path
                    end
                end
                
                FIRST_CHAR_WRITE_ROW0: begin
                    // Write row 0 of glyph data
                    write_glyph_row(3'd0);
                    unified_state <= FIRST_CHAR_WRITE_ROW1;
                end
                
                FIRST_CHAR_WRITE_ROW1: begin
                    // Write row 1 of glyph data
                    write_glyph_row(3'd1);
                    unified_state <= FIRST_CHAR_WRITE_ROW2;
                end
                
                FIRST_CHAR_WRITE_ROW2: begin
                    // Write row 2 of glyph data
                    write_glyph_row(3'd2);
                    unified_state <= FIRST_CHAR_WRITE_ROW3;
                end
                
                FIRST_CHAR_WRITE_ROW3: begin
                    // Write row 3 of glyph data
                    write_glyph_row(3'd3);
                    unified_state <= FIRST_CHAR_WRITE_ROW4;
                end
                
                FIRST_CHAR_WRITE_ROW4: begin
                    // Write row 4 of glyph data
                    write_glyph_row(3'd4);
                    unified_state <= FIRST_CHAR_WRITE_ROW5;
                end
                
                FIRST_CHAR_WRITE_ROW5: begin
                    // Write row 5 of glyph data
                    write_glyph_row(3'd5);
                    unified_state <= FIRST_CHAR_WRITE_ROW6;
                end
                
                FIRST_CHAR_WRITE_ROW6: begin
                    // Write row 6 of glyph data
                    write_glyph_row(3'd6);
                    unified_state <= FIRST_CHAR_WRITE_ROW7;
                end
                
                FIRST_CHAR_WRITE_ROW7: begin
                    // Write row 7 of glyph data
                    write_glyph_row(3'd7);
                    unified_state <= FIRST_CHAR_CURSOR_UPDATE;  // No more color write
                end
                
                FIRST_CHAR_CURSOR_UPDATE: begin
                    // Update cursor position based on first character
                    if (processing_fixpos_mode) begin
                        // FixPos=1: First set auto-cursor to explicit position
                        cursor_x <= processing_write_x;
                        cursor_y <= processing_write_y;
                        
                        // Then apply advancement based on character type
                        if (first_char_stored == 7'h00 || first_char_stored == 7'h7F) begin  // NUL or DEL
                            // No additional movement beyond setting position
                        end else if (first_char_stored == 7'h08) begin  // BS (Backspace)
                            // BS already pre-moved cursor during setup, don't advance further
                        end else if (first_char_stored == 7'h0A) begin  // LF
                            // LF: move to start of next line from explicit position
                            cursor_x <= 6'd0;
                            cursor_y <= (processing_write_y == 24) ? 5'd0 : processing_write_y + 1;
                        end else if (first_char_stored == 7'h0B) begin  // VT
                            // VT: move row+1 and col+1 from explicit position
                            if (processing_write_x == 39) begin
                                cursor_x <= 6'd0;
                                cursor_y <= (processing_write_y >= 23) ? 5'd0 : processing_write_y + 2;
                            end else begin
                                cursor_x <= processing_write_x + 1;
                                cursor_y <= (processing_write_y == 24) ? 5'd0 : processing_write_y + 1;
                            end
                        end else if (first_char_stored == 7'h0C) begin  // FF
                            // FF: move to home (already done in setup)
                            cursor_x <= 6'd0;
                            cursor_y <= 5'd0;
                        end else if (first_char_stored == 7'h0D) begin  // CR
                            // CR: move to start of current line
                            cursor_x <= 6'd0;
                            cursor_y <= processing_write_y;
                        end else begin
                            // Normal character: advance from explicit position
                            if (processing_write_x == 39) begin
                                cursor_x <= 6'd0;
                                cursor_y <= (processing_write_y == 24) ? 5'd0 : processing_write_y + 1;
                            end else begin
                                cursor_x <= processing_write_x + 1;
                                cursor_y <= processing_write_y;
                            end
                        end
                    end else begin
                        // FixPos=0: Normal cursor advancement from current position
                        if (first_char_stored == 7'h00 || first_char_stored == 7'h7F) begin  // NUL or DEL
                            // No cursor movement
                        end else if (first_char_stored == 7'h08) begin  // BS (Backspace)
                            // Cursor already moved during setup
                        end else if (first_char_stored == 7'h0A || first_char_stored == 7'h0B || first_char_stored == 7'h0C || first_char_stored == 7'h0D) begin
                            // LF, VT, FF, CR - cursor already moved during setup
                        end else begin
                            // Normal character advancement
                            if (cursor_x == 39) begin
                                cursor_x <= 6'd0;
                                cursor_y <= (cursor_y == 24) ? 5'd0 : cursor_y + 1;
                            end else begin
                                cursor_x <= cursor_x + 1;
                            end
                        end
                    end
                    
                    // Move to second character or done
                    unified_state <= second_char_valid ? SECOND_CHAR_SETUP : UNIFIED_IDLE;
                end
                
                // FIRST CHARACTER ADD MODE PROCESSING
                FIRST_CHAR_READ_ROW0: begin
                    // Start reading row 0
                    fb_addr <= pixel_base_addr + 3'd0 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;  // Read only
                    unified_state <= FIRST_CHAR_READ_ROW1;
                end
                
                FIRST_CHAR_READ_ROW1: begin
                    // Store row 0 data that became available, start reading row 1
                    read_row_data[0] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd1 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= FIRST_CHAR_READ_ROW2;
                end
                
                FIRST_CHAR_READ_ROW2: begin
                    // Store row 1 data, start reading row 2
                    read_row_data[1] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd2 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= FIRST_CHAR_READ_ROW3;
                end
                
                FIRST_CHAR_READ_ROW3: begin
                    // Store row 2 data, start reading row 3
                    read_row_data[2] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd3 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= FIRST_CHAR_READ_ROW4;
                end
                
                FIRST_CHAR_READ_ROW4: begin
                    // Store row 3 data, start reading row 4
                    read_row_data[3] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd4 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= FIRST_CHAR_READ_ROW5;
                end
                
                FIRST_CHAR_READ_ROW5: begin
                    // Store row 4 data, start reading row 5
                    read_row_data[4] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd5 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= FIRST_CHAR_READ_ROW6;
                end
                
                FIRST_CHAR_READ_ROW6: begin
                    // Store row 5 data, start reading row 6
                    read_row_data[5] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd6 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= FIRST_CHAR_READ_ROW7;
                end
                
                FIRST_CHAR_READ_ROW7: begin
                    // Store row 6 data, start reading row 7
                    read_row_data[6] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd7 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= FIRST_CHAR_ADD_ROW0;
                end
                
                FIRST_CHAR_ADD_ROW0: begin
                    // Store row 7 data, OR and write row 0
                    read_row_data[7] <= fb_read_data;
                    write_glyph_row_add(3'd0);
                    unified_state <= FIRST_CHAR_ADD_ROW1;
                end
                
                FIRST_CHAR_ADD_ROW1: begin
                    // OR and write row 1
                    write_glyph_row_add(3'd1);
                    unified_state <= FIRST_CHAR_ADD_ROW2;
                end
                
                FIRST_CHAR_ADD_ROW2: begin
                    // OR and write row 2
                    write_glyph_row_add(3'd2);
                    unified_state <= FIRST_CHAR_ADD_ROW3;
                end
                
                FIRST_CHAR_ADD_ROW3: begin
                    // OR and write row 3
                    write_glyph_row_add(3'd3);
                    unified_state <= FIRST_CHAR_ADD_ROW4;
                end
                
                FIRST_CHAR_ADD_ROW4: begin
                    // OR and write row 4
                    write_glyph_row_add(3'd4);
                    unified_state <= FIRST_CHAR_ADD_ROW5;
                end
                
                FIRST_CHAR_ADD_ROW5: begin
                    // OR and write row 5
                    write_glyph_row_add(3'd5);
                    unified_state <= FIRST_CHAR_ADD_ROW6;
                end
                
                FIRST_CHAR_ADD_ROW6: begin
                    // OR and write row 6
                    write_glyph_row_add(3'd6);
                    unified_state <= FIRST_CHAR_ADD_ROW7;
                end
                
                FIRST_CHAR_ADD_ROW7: begin
                    // OR and write row 7
                    write_glyph_row_add(3'd7);
                    unified_state <= FIRST_CHAR_CURSOR_UPDATE;  // Continue to cursor update
                end
                
                // SECOND CHARACTER PROCESSING
                SECOND_CHAR_SETUP: begin
                    current_char_invert <= second_char_invert;  // Set invert flag for second char
                    
                    // Both modes now use the updated auto-cursor position
                    char_write_x <= cursor_x;
                    char_write_y <= cursor_y;
                    
                    // Handle special characters
                    if (second_char_stored == 7'h08) begin  // BS (Backspace)
                        // Pre-move cursor for backspace
                        if (cursor_x == 0) begin
                            char_write_x <= 6'd39;
                            char_write_y <= (cursor_y == 0) ? 5'd24 : cursor_y - 1;
                            cursor_x <= 6'd39;
                            cursor_y <= (cursor_y == 0) ? 5'd24 : cursor_y - 1;
                        end else begin
                            char_write_x <= cursor_x - 1;
                            char_write_y <= cursor_y;
                            cursor_x <= cursor_x - 1;
                        end
                        char_to_write <= 7'h20;  // Write space
                        unified_state <= SECOND_CHAR_CALC_ADDR;
                    end else if (second_char_stored == 7'h0A) begin  // LF
                        // Line feed - just move cursor
                        cursor_x <= 6'd0;
                        cursor_y <= (cursor_y == 24) ? 5'd0 : cursor_y + 1;
                        unified_state <= SECOND_CHAR_CURSOR_UPDATE;  // Skip to cursor update
                    end else if (second_char_stored == 7'h0B) begin  // VT (Vertical Tab)
                        // Vertical tab - move cursor row+1 and col+1
                        if (cursor_x == 39) begin
                            // X wraps, Y increments by 2 (1 for VT, 1 for wrap)
                            cursor_x <= 6'd0;
                            cursor_y <= (cursor_y >= 23) ? 5'd0 : cursor_y + 2;
                        end else begin
                            // Normal VT movement
                            cursor_x <= cursor_x + 1;
                            cursor_y <= (cursor_y == 24) ? 5'd0 : cursor_y + 1;
                        end
                        unified_state <= SECOND_CHAR_CURSOR_UPDATE;  // Skip to cursor update
                    end else if (second_char_stored == 7'h0C) begin  // FF
                        // Form feed - move cursor to home
                        cursor_x <= 6'd0;
                        cursor_y <= 5'd0;
                        unified_state <= SECOND_CHAR_CURSOR_UPDATE;  // Skip to cursor update
                    end else if (second_char_stored == 7'h0D) begin  // CR
                        // Carriage return - move cursor to start of line
                        cursor_x <= 6'd0;
                        unified_state <= SECOND_CHAR_CURSOR_UPDATE;  // Skip to cursor update
                    end else if (second_char_stored == 7'h00 || second_char_stored == 7'h7F) begin  // NUL or DEL
                        // NUL/DEL - no action, done
                        unified_state <= UNIFIED_IDLE;
                    end else begin
                        // Normal character - write it
                        if (second_char_stored == 7'h09) begin
                            char_to_write <= 7'h20;  // Tab becomes space
                        end else begin
                            char_to_write <= second_char_stored;
                        end
                        unified_state <= SECOND_CHAR_CALC_ADDR;
                    end
                end
                
                SECOND_CHAR_CALC_ADDR: begin
                    // Calculate base addresses for pixel data
                    pixel_base_addr <= (char_write_y * 16'd8 * FRAME_WIDTH + char_write_x * 16'd8) >> 3;  // Byte address (divide by 8)
                    unified_state <= SECOND_CHAR_FETCH_GLYPH;
                end
                
                SECOND_CHAR_FETCH_GLYPH: begin
                    unified_state <= SECOND_CHAR_WAIT_GLYPH;
                end
                
                SECOND_CHAR_WAIT_GLYPH: begin
                    if (char_add_mode) begin
                        unified_state <= SECOND_CHAR_READ_ROW0;  // Add mode path
                    end else begin
                        unified_state <= SECOND_CHAR_WRITE_ROW0; // Normal mode path
                    end
                end
                
                SECOND_CHAR_WRITE_ROW0: begin
                    // Write row 0 of glyph data
                    write_glyph_row(3'd0);
                    unified_state <= SECOND_CHAR_WRITE_ROW1;
                end
                
                SECOND_CHAR_WRITE_ROW1: begin
                    // Write row 1 of glyph data
                    write_glyph_row(3'd1);
                    unified_state <= SECOND_CHAR_WRITE_ROW2;
                end
                
                SECOND_CHAR_WRITE_ROW2: begin
                    // Write row 2 of glyph data
                    write_glyph_row(3'd2);
                    unified_state <= SECOND_CHAR_WRITE_ROW3;
                end
                
                SECOND_CHAR_WRITE_ROW3: begin
                    // Write row 3 of glyph data
                    write_glyph_row(3'd3);
                    unified_state <= SECOND_CHAR_WRITE_ROW4;
                end
                
                SECOND_CHAR_WRITE_ROW4: begin
                    // Write row 4 of glyph data
                    write_glyph_row(3'd4);
                    unified_state <= SECOND_CHAR_WRITE_ROW5;
                end
                
                SECOND_CHAR_WRITE_ROW5: begin
                    // Write row 5 of glyph data
                    write_glyph_row(3'd5);
                    unified_state <= SECOND_CHAR_WRITE_ROW6;
                end
                
                SECOND_CHAR_WRITE_ROW6: begin
                    // Write row 6 of glyph data
                    write_glyph_row(3'd6);
                    unified_state <= SECOND_CHAR_WRITE_ROW7;
                end
                
                SECOND_CHAR_WRITE_ROW7: begin
                    // Write row 7 of glyph data
                    write_glyph_row(3'd7);
                    unified_state <= SECOND_CHAR_CURSOR_UPDATE;  // No more color write
                end
                
                SECOND_CHAR_CURSOR_UPDATE: begin
                    // Update cursor position based on second character
                    // Both modes use the same cursor advancement logic
                    if (second_char_stored == 7'h00 || second_char_stored == 7'h7F) begin  // NUL or DEL
                        // No cursor movement
                    end else if (second_char_stored == 7'h08) begin  // BS (Backspace)
                        // Cursor already moved during setup
                    end else if (second_char_stored == 7'h0A || second_char_stored == 7'h0B || second_char_stored == 7'h0C || second_char_stored == 7'h0D) begin
                        // LF, VT, FF, CR - cursor already moved during setup
                    end else begin
                        // Normal character advancement
                        if (cursor_x == 39) begin
                            cursor_x <= 6'd0;
                            cursor_y <= (cursor_y == 24) ? 5'd0 : cursor_y + 1;
                        end else begin
                            cursor_x <= cursor_x + 1;
                        end
                    end
                    
                    // Done with both characters
                    unified_state <= UNIFIED_IDLE;
                end
                
                // SECOND CHARACTER ADD MODE PROCESSING
                SECOND_CHAR_READ_ROW0: begin
                    // Start reading row 0
                    fb_addr <= pixel_base_addr + 3'd0 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;  // Read only
                    unified_state <= SECOND_CHAR_READ_ROW1;
                end
                
                SECOND_CHAR_READ_ROW1: begin
                    // Store row 0 data that became available, start reading row 1
                    read_row_data[0] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd1 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= SECOND_CHAR_READ_ROW2;
                end
                
                SECOND_CHAR_READ_ROW2: begin
                    // Store row 1 data, start reading row 2
                    read_row_data[1] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd2 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= SECOND_CHAR_READ_ROW3;
                end
                
                SECOND_CHAR_READ_ROW3: begin
                    // Store row 2 data, start reading row 3
                    read_row_data[2] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd3 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= SECOND_CHAR_READ_ROW4;
                end
                
                SECOND_CHAR_READ_ROW4: begin
                    // Store row 3 data, start reading row 4
                    read_row_data[3] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd4 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= SECOND_CHAR_READ_ROW5;
                end
                
                SECOND_CHAR_READ_ROW5: begin
                    // Store row 4 data, start reading row 5
                    read_row_data[4] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd5 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= SECOND_CHAR_READ_ROW6;
                end
                
                SECOND_CHAR_READ_ROW6: begin
                    // Store row 5 data, start reading row 6
                    read_row_data[5] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd6 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= SECOND_CHAR_READ_ROW7;
                end
                
                SECOND_CHAR_READ_ROW7: begin
                    // Store row 6 data, start reading row 7
                    read_row_data[6] <= fb_read_data;
                    fb_addr <= pixel_base_addr + 3'd7 * COLOR_CELLS_X;
                    fb_write_enable <= 1'b0;
                    unified_state <= SECOND_CHAR_ADD_ROW0;
                end
                
                SECOND_CHAR_ADD_ROW0: begin
                    // Store row 7 data, OR and write row 0
                    read_row_data[7] <= fb_read_data;
                    write_glyph_row_add(3'd0);
                    unified_state <= SECOND_CHAR_ADD_ROW1;
                end
                
                SECOND_CHAR_ADD_ROW1: begin
                    // OR and write row 1
                    write_glyph_row_add(3'd1);
                    unified_state <= SECOND_CHAR_ADD_ROW2;
                end
                
                SECOND_CHAR_ADD_ROW2: begin
                    // OR and write row 2
                    write_glyph_row_add(3'd2);
                    unified_state <= SECOND_CHAR_ADD_ROW3;
                end
                
                SECOND_CHAR_ADD_ROW3: begin
                    // OR and write row 3
                    write_glyph_row_add(3'd3);
                    unified_state <= SECOND_CHAR_ADD_ROW4;
                end
                
                SECOND_CHAR_ADD_ROW4: begin
                    // OR and write row 4
                    write_glyph_row_add(3'd4);
                    unified_state <= SECOND_CHAR_ADD_ROW5;
                end
                
                SECOND_CHAR_ADD_ROW5: begin
                    // OR and write row 5
                    write_glyph_row_add(3'd5);
                    unified_state <= SECOND_CHAR_ADD_ROW6;
                end
                
                SECOND_CHAR_ADD_ROW6: begin
                    // OR and write row 6
                    write_glyph_row_add(3'd6);
                    unified_state <= SECOND_CHAR_ADD_ROW7;
                end
                
                SECOND_CHAR_ADD_ROW7: begin
                    // OR and write row 7
                    write_glyph_row_add(3'd7);
                    unified_state <= SECOND_CHAR_CURSOR_UPDATE;  // Continue to cursor update (no color write)
                end
                
                default: begin
                    unified_state <= UNIFIED_IDLE;
                end
            endcase
        end
        
        // Handle register writes (blocked if busy or clear in progress)
        if ((write_req && device_select) && !busy && !clear_in_progress) begin        
            case (register_offset)
                REG_CHAR_INPUT: begin
                    char_input_reg <= wdata;
                end
                REG_CHAR_COORDINATES: begin
                    // Store combined coordinates
                    text_coordinates_reg <= wdata;
                end
                REG_CHAR_CONTROL: begin
                    if (wdata[8]) begin  // PutChar
                        // Start unified character processing if idle
                        if (unified_state == UNIFIED_IDLE) begin
                            // Store characters, invert flags, and processing modes directly
                            first_char_stored <= char_input_reg[6:0];     // ASCII1
                            second_char_stored <= char_input_reg[14:8];   // ASCII2
                            first_char_invert <= char_input_reg[7];       // Invert1
                            second_char_invert <= char_input_reg[15];     // Invert2
                            second_char_valid <= (char_input_reg[14:8] != 7'h00 && char_input_reg[14:8] != 7'h7F);
                            processing_fixpos_mode <= wdata[9];
                            char_add_mode <= wdata[10];  // Store Add mode (bit 10)
                            
                            // Store write position for FixPos=1 mode
                            if (wdata[9]) begin  // FixPos == 1
                                // Extract coordinates from combined register
                                automatic logic [5:0] coord_x;
                                automatic logic [4:0] coord_y;
                                coord_x = text_coordinates_reg[5:0];   // X (0-39)
                                coord_y = text_coordinates_reg[12:8];  // Y (0-24)
                                
                                // Validate coordinates are in bounds
                                if (coord_x < 40 && coord_y < 25) begin
                                    processing_write_x <= coord_x;
                                    processing_write_y <= coord_y;
                                    
                                    // Start unified state machine
                                    unified_state <= FIRST_CHAR_SETUP;
                                end
                                // else: coordinates out of bounds, ignore
                            end else begin
                                // FixPos == 0, use auto-cursor
                                // Start unified state machine
                                unified_state <= FIRST_CHAR_SETUP;
                            end
                        end
                    end
                    if (wdata[11]) begin  // Clear
                        // Request clear operation from main module
                        clear_request_reg <= 1'b1;
                    end
                end
                default: begin
                    // Unknown register - do nothing
                end
            endcase
        end  // end if register writes
    end
end

// Read interface
always_comb begin
    if (device_select) begin
        unique case (register_offset)
            REG_CHAR_INPUT: begin
                rdata = char_input_reg;
            end
            REG_CHAR_COORDINATES: begin
                // Return current auto-cursor position in combined format
                rdata = {3'b000, cursor_y, 2'b00, cursor_x};
            end
            REG_CHAR_CONTROL: begin
                rdata = 16'h0000;  // Write-only register
            end
            default: begin
                rdata = 16'hXXXX;  // Don't care
            end
        endcase
    end else begin
        rdata = 16'hXXXX;       // Don't care
    end
end

endmodule
