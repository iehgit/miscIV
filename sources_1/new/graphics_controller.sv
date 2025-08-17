module graphics_controller (
    input  logic        clk,
    input  logic        reset,
    
    // Memory-mapped register interface (graphics registers only: 0x5-0x7)
    input  logic        device_select,      // Pre-qualified for graphics registers
    input  logic [3:0]  register_offset,   
    input  logic        write_req,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,
    
    // Frame buffer interface (generic - main module handles A/B selection)
    output logic [13:0] fb_addr,
    output logic [7:0]  fb_data,
    output logic        fb_write_enable,
    input  logic [7:0]  fb_read_data,       // For Add mode reads
    
    // Clear operation interface
    output logic        clear_request,      // Request frame buffer clear
    input  logic        clear_in_progress,  // Main module performing clear
    
    // Status
    output logic        busy                // Graphics operations in progress
);

// Frame buffer parameters (same as main module)
localparam FRAME_WIDTH = 320;
localparam COLOR_CELLS_X = 40;

// Graphics register addresses (updated mapping)
localparam REG_PIXEL_DATA = 4'h5;
localparam REG_GRAPHICS_COORDINATES = 4'h6;  // Combined X/Y
localparam REG_GRAPHICS_CONTROL = 4'h7;      // Moved from 0x9

// Graphics registers
logic [15:0] pixel_data_reg;
logic [15:0] graphics_coordinates_reg;  // Combined: Y(15:8), X(5:0)

// Auto-cursor position registers (for FixPos=0)
logic [5:0] cursor_x;  // 0-39 (byte positions, only 6 bits needed)
logic [7:0] cursor_y;  // 0-199 (pixel rows, 8 bits needed)

// Processing mode storage
logic processing_fixpos_mode;   // Store FixPos mode for current operation
logic [5:0] processing_write_x; // Store write position for FixPos=1 mode
logic [7:0] processing_write_y;

// Add mode support
logic graphics_add_mode;        // Store Add mode flag from control register
logic [7:0] read_byte0_data;    // Store read data for first byte
logic [7:0] read_byte1_data;    // Store read data for second byte

// PutPixel state machine
typedef enum logic [3:0] {
    GRAPHICS_IDLE,
    PIXEL_SETUP,
    // Normal mode states
    PIXEL_WRITE_BYTE0,
    PIXEL_WRITE_BYTE1,
    // Add mode states
    PIXEL_READ_BYTE0,
    PIXEL_READ_BYTE1,
    PIXEL_ADD_BYTE0,
    PIXEL_ADD_BYTE1,
    PIXEL_CURSOR_UPDATE
} graphics_state_t;

graphics_state_t graphics_state;

// PutPixel operation signals
logic [13:0] pixel_byte0_addr;      // Address for first pixel byte
logic [13:0] pixel_byte1_addr;      // Address for second pixel byte

// Pixel data processing
logic [7:0] pixel_byte0, pixel_byte1;

// Simple direct mapping - VGA module handles display bit ordering
assign pixel_byte0 = pixel_data_reg[7:0];   // First 8 pixels  
assign pixel_byte1 = pixel_data_reg[15:8];  // Second 8 pixels

// Busy signal - true when any operation is in progress
assign busy = (graphics_state != GRAPHICS_IDLE);

// Clear request handling
logic clear_request_reg;
assign clear_request = clear_request_reg;

// Main sequential logic
always_ff @(posedge clk) begin
    if (reset) begin
        // Graphics registers
        pixel_data_reg <= 16'h0000;
        graphics_coordinates_reg <= 16'h0000;
        
        // Auto-cursor
        cursor_x <= 6'd0;
        cursor_y <= 8'd0;
        
        // Processing mode storage
        processing_fixpos_mode <= 1'b0;
        processing_write_x <= 6'd0;
        processing_write_y <= 8'd0;
        
        // Add mode support
        graphics_add_mode <= 1'b0;
        read_byte0_data <= 8'h00;
        read_byte1_data <= 8'h00;
        
        // State machine
        graphics_state <= GRAPHICS_IDLE;
        pixel_byte0_addr <= 14'd0;
        pixel_byte1_addr <= 14'd0;
        
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
        if (clear_in_progress && graphics_state == GRAPHICS_IDLE) begin
            cursor_x <= 6'd0;
            cursor_y <= 8'd0;
        end
        
        // Graphics state machine - handles PutPixel operation
        if (graphics_state != GRAPHICS_IDLE) begin
            case (graphics_state)
                PIXEL_SETUP: begin
                    automatic logic [5:0]  pixel_write_x;         // X coordinate for current pixel write (0-39, byte position)
                    automatic logic [7:0]  pixel_write_y;         // Y coordinate for current pixel write (0-199)
                
                    // Determine coordinates based on FixPos mode
                    if (processing_fixpos_mode) begin
                        // FixPos=1: Use explicit coordinates
                        pixel_write_x = graphics_coordinates_reg[5:0];   // X (0-39)
                        pixel_write_y = graphics_coordinates_reg[15:8];  // Y (0-199)
                    end else begin
                        // FixPos=0: Use auto-cursor
                        pixel_write_x = cursor_x;
                        pixel_write_y = cursor_y;
                    end
                    
                    // Calculate pixel addresses with wrapping
                    // First byte: y * 40 + x
                    if (processing_fixpos_mode) begin
                        pixel_byte0_addr <= (graphics_coordinates_reg[15:8] * COLOR_CELLS_X) + graphics_coordinates_reg[5:0];
                        
                        // Second byte: handle wrapping at end of line
                        if (graphics_coordinates_reg[5:0] == 6'd39) begin
                            // At end of line, wrap to beginning of next line
                            if (graphics_coordinates_reg[15:8] == 8'd199) begin
                                // At bottom-right corner, wrap to (0,0)
                                pixel_byte1_addr <= 14'd0;
                            end else begin
                                // Wrap to beginning of next line
                                pixel_byte1_addr <= ((graphics_coordinates_reg[15:8] + 1) * COLOR_CELLS_X);
                            end
                        end else begin
                            // Normal case: just next byte position
                            pixel_byte1_addr <= (graphics_coordinates_reg[15:8] * COLOR_CELLS_X) + graphics_coordinates_reg[5:0] + 14'd1;
                        end
                    end else begin
                        // Auto-cursor mode
                        pixel_byte0_addr <= (cursor_y * COLOR_CELLS_X) + cursor_x;
                        
                        // Second byte: handle wrapping at end of line
                        if (cursor_x == 6'd39) begin
                            // At end of line, wrap to beginning of next line
                            if (cursor_y == 8'd199) begin
                                // At bottom-right corner, wrap to (0,0)
                                pixel_byte1_addr <= 14'd0;
                            end else begin
                                // Wrap to beginning of next line
                                pixel_byte1_addr <= ((cursor_y + 1) * COLOR_CELLS_X);
                            end
                        end else begin
                            // Normal case: just next byte position
                            pixel_byte1_addr <= (cursor_y * COLOR_CELLS_X) + cursor_x + 14'd1;
                        end
                    end
                    
                    // Branch based on Add mode
                    if (graphics_add_mode) begin
                        graphics_state <= PIXEL_READ_BYTE0;  // Add mode path
                    end else begin
                        graphics_state <= PIXEL_WRITE_BYTE0; // Normal mode path
                    end
                end
                
                PIXEL_WRITE_BYTE0: begin
                    // Write first 8 pixels
                    fb_addr <= pixel_byte0_addr;
                    fb_data <= pixel_byte0;
                    fb_write_enable <= 1'b1;
                    graphics_state <= PIXEL_WRITE_BYTE1;
                end
                
                PIXEL_WRITE_BYTE1: begin
                    // Write second 8 pixels
                    fb_addr <= pixel_byte1_addr;
                    fb_data <= pixel_byte1;
                    fb_write_enable <= 1'b1;
                    graphics_state <= PIXEL_CURSOR_UPDATE;
                end
                
                // Add mode states
                PIXEL_READ_BYTE0: begin
                    // Issue read for first byte
                    fb_addr <= pixel_byte0_addr;
                    fb_write_enable <= 1'b0;  // Read only
                    graphics_state <= PIXEL_READ_BYTE1;
                end
                
                PIXEL_READ_BYTE1: begin
                    // Store first byte data, issue read for second byte
                    read_byte0_data <= fb_read_data;  // Data from previous cycle
                    fb_addr <= pixel_byte1_addr;
                    fb_write_enable <= 1'b0;  // Read only
                    graphics_state <= PIXEL_ADD_BYTE0;
                end
                
                PIXEL_ADD_BYTE0: begin
                    // Store second byte data, write OR'd first byte
                    read_byte1_data <= fb_read_data;  // Data from previous cycle
                    fb_addr <= pixel_byte0_addr;
                    fb_data <= read_byte0_data | pixel_byte0;  // OR operation
                    fb_write_enable <= 1'b1;
                    graphics_state <= PIXEL_ADD_BYTE1;
                end
                
                PIXEL_ADD_BYTE1: begin
                    // Write OR'd second byte
                    fb_addr <= pixel_byte1_addr;
                    fb_data <= read_byte1_data | pixel_byte1;  // OR operation
                    fb_write_enable <= 1'b1;
                    graphics_state <= PIXEL_CURSOR_UPDATE;
                end
                
                PIXEL_CURSOR_UPDATE: begin
                    // Update cursor position
                    if (processing_fixpos_mode) begin
                        // FixPos=1: Sync cursor to explicit position first
                        cursor_x <= processing_write_x;
                        cursor_y <= processing_write_y;
                        
                        // Then advance by 2 from that position
                        if (processing_write_x <= 37) begin
                            // Normal advancement by 2
                            cursor_x <= processing_write_x + 2;
                        end else if (processing_write_x == 38) begin
                            // Wrap to beginning of next line
                            cursor_x <= 6'd0;
                            cursor_y <= (processing_write_y == 199) ? 8'd0 : processing_write_y + 1;
                        end else begin  // processing_write_x == 39
                            // Wrap to position 1 of next line
                            cursor_x <= 6'd1;
                            cursor_y <= (processing_write_y == 199) ? 8'd0 : processing_write_y + 1;
                        end
                    end else begin
                        // FixPos=0: Advance cursor by 2 from current position
                        if (cursor_x <= 37) begin
                            // Normal advancement by 2
                            cursor_x <= cursor_x + 2;
                        end else if (cursor_x == 38) begin
                            // Wrap to beginning of next line
                            cursor_x <= 6'd0;
                            cursor_y <= (cursor_y == 199) ? 8'd0 : cursor_y + 1;
                        end else begin  // cursor_x == 39
                            // Wrap to position 1 of next line
                            cursor_x <= 6'd1;
                            cursor_y <= (cursor_y == 199) ? 8'd0 : cursor_y + 1;
                        end
                    end
                    
                    graphics_state <= GRAPHICS_IDLE;
                end
                
                default: begin
                    graphics_state <= GRAPHICS_IDLE;
                end
            endcase
        end
        
        // Handle register writes (blocked if busy or clear in progress)
        if ((write_req && device_select) && !busy && !clear_in_progress) begin            
            case (register_offset)
                REG_PIXEL_DATA: begin
                    pixel_data_reg <= wdata;
                end
                REG_GRAPHICS_COORDINATES: begin
                    graphics_coordinates_reg <= wdata;
                end
                REG_GRAPHICS_CONTROL: begin
                    if (wdata[8]) begin  // PutPixel
                        // Start PutPixel operation if idle
                        if (graphics_state == GRAPHICS_IDLE) begin
                            // Store processing modes
                            processing_fixpos_mode <= wdata[9];
                            graphics_add_mode <= wdata[10];  // Store Add mode
                            
                            // For FixPos=1, validate and store explicit coordinates
                            if (wdata[9]) begin
                                // Validate coordinates
                                if (graphics_coordinates_reg[5:0] <= 6'd39 && graphics_coordinates_reg[15:8] <= 8'd199) begin
                                    processing_write_x <= graphics_coordinates_reg[5:0];
                                    processing_write_y <= graphics_coordinates_reg[15:8];
                                    graphics_state <= PIXEL_SETUP;
                                end
                                // else: invalid coordinates, ignore
                            end else begin
                                // FixPos=0: Use auto-cursor (always valid)
                                graphics_state <= PIXEL_SETUP;
                            end
                        end
                        // If busy, ignore the operation
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
            REG_PIXEL_DATA: begin
                rdata = pixel_data_reg;
            end
            REG_GRAPHICS_COORDINATES: begin
                // Return current auto-cursor position
                rdata = {cursor_y, 2'b00, cursor_x};
            end
            REG_GRAPHICS_CONTROL: begin
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
