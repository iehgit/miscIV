module gpu (
    input  logic        clk,
    input  logic        reset,
    
    // Memory-mapped I/O interface
    input  logic        device_select,
    input  logic [3:0]  register_offset,
    input  logic        read_req,
    input  logic        write_req,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,
    
    // VGA output (directly from internal vga_timing)
    output logic [3:0]  vga_r, vga_g, vga_b,
    output logic        vga_hsync, vga_vsync
);

// Frame buffer parameters (320x200 monochrome)
localparam FRAME_WIDTH = 320;
localparam FRAME_HEIGHT = 200;
localparam PIXELS_PER_FRAME = FRAME_WIDTH * FRAME_HEIGHT;  // 64,000
localparam BYTES_PER_FRAME = PIXELS_PER_FRAME / 8;         // 8,000 bytes
localparam COLOR_DATA_OFFSET = 8000;                       // Color data starts at byte 8000
localparam COLOR_CELLS_X = 40;                             // 40 color cells horizontally
localparam PALETTE_DATA_ADDR = 9000;                       // Start of 4-byte packed palette data
localparam ADDR_BITS = 14;  // 2^14 = 16384 bytes (expanded for color data + palette data)

// Memory-mapped register addresses
// Text Interface (handled by text_controller)
localparam REG_CHAR_INPUT = 4'h0;
localparam REG_CHAR_COORDINATES = 4'h1;  // Combined X/Y
localparam REG_CHAR_CONTROL = 4'h2;      // Moved from 0x4

// Graphics Interface (handled by graphics_controller)
localparam REG_PIXEL_DATA = 4'h5;
localparam REG_GRAPHICS_COORDINATES = 4'h6;  // Combined X/Y
localparam REG_GRAPHICS_CONTROL = 4'h7;      // Moved from 0x9

// Common Interface
localparam REG_PALETTE_CHOICE_1 = 4'hA;
localparam REG_PALETTE_CHOICE_2 = 4'hB;
localparam REG_FLIP_CONTROL = 4'hC;

// Color Interface (handled by color_controller)
localparam REG_COLOR_VALUES = 4'hD;       // Color cell fg/bg values
localparam REG_COLOR_COORDINATES = 4'hE;  // Color cell coordinates
localparam REG_COLOR_CONTROL = 4'hF;      // Color cell control

// Address decode for module selection
logic text_select, graphics_select, color_select;
assign text_select = device_select && (register_offset <= 4'h2);  // 0x0-0x2
assign graphics_select = device_select && (4'h5 <= register_offset && register_offset <= 4'h7);  // 0x5-0x7
assign color_select = device_select && (4'hD <= register_offset && register_offset <= 4'hF);  // 0xD-0xF

// Common registers
logic [24:0] palette_choice_bits;
logic        write_buffer;    // 0=Buffer A, 1=Buffer B for writes
logic        display_buffer;  // 0=Buffer A, 1=Buffer B for display

// Palette update control - separate for each register
logic palette1_write_pending;  // For REG_PALETTE_CHOICE_1 (bytes 0-1)
logic palette1_write_byte1;    // Which byte to write (0 or 1)
logic palette2_write_pending;  // For REG_PALETTE_CHOICE_2 (bytes 2-3)
logic palette2_write_byte3;    // Which byte to write (0=byte2, 1=byte3)

// Clear operation control
logic clear_pending;           // True when pixel clear operation is active
logic [12:0] clear_address;    // Current address being cleared (0-7999)

// Color clear operation control
logic color_clear_pending;     // True when color clear operation is active
logic [9:0] color_clear_address; // Current address being cleared (0-999)

// Frame buffer write interfaces to vga_timing (direct to BRAM ports)
logic [ADDR_BITS-1:0] fb_a_write_addr, fb_b_write_addr;
logic [7:0] fb_a_write_data, fb_b_write_data;
logic fb_a_write_enable, fb_b_write_enable;
logic [7:0] fb_a_read_data, fb_b_read_data;  // Read data from TDP BRAM (for Add mode)
logic desired_buffer;  // 0=Buffer A, 1=Buffer B for display

// Frame buffer read data mux - selects read data based on write buffer
logic [7:0] fb_read_data;
always_comb begin
    fb_read_data = (write_buffer == 1'b0) ? fb_a_read_data : fb_b_read_data;
end

// Separate signals for initialization and CPU access
logic [ADDR_BITS-1:0] cpu_addr;
logic [7:0] cpu_data;
logic cpu_write_en;

// Text controller interface signals
logic [13:0] text_fb_addr;
logic [7:0]  text_fb_data;
logic        text_fb_write_enable;
logic        text_clear_request;
logic        text_busy;
logic [15:0] text_rdata;

// Graphics controller interface signals
logic [13:0] graphics_fb_addr;
logic [7:0]  graphics_fb_data;
logic        graphics_fb_write_enable;
logic        graphics_clear_request;
logic        graphics_busy;
logic [15:0] graphics_rdata;

// Color controller interface signals
logic [13:0] color_fb_addr;
logic [7:0]  color_fb_data;
logic        color_fb_write_enable;
logic        color_clear_request;
logic        color_busy;
logic [15:0] color_rdata;

// Registered read data for timing closure
logic [15:0] rdata_reg;

// VGA timing generator with internal BRAM frame buffers
vga vga (
    .clk(clk),
    
    // Frame buffer A write interface (direct to BRAM Port A)
    .fb_a_write_addr(fb_a_write_addr),
    .fb_a_write_data(fb_a_write_data),
    .fb_a_write_enable(fb_a_write_enable),
    .fb_a_read_data(fb_a_read_data),      // Read data from buffer A
    
    // Frame buffer B write interface (direct to BRAM Port A)
    .fb_b_write_addr(fb_b_write_addr),
    .fb_b_write_data(fb_b_write_data),
    .fb_b_write_enable(fb_b_write_enable),
    .fb_b_read_data(fb_b_read_data),      // Read data from buffer B
    
    // Display control interface
    .desired_buffer(desired_buffer),
    
    // VGA outputs (direct from 25MHz domain)
    .hsync(vga_hsync),
    .vsync(vga_vsync),
    .vga_r(vga_r),
    .vga_g(vga_g),
    .vga_b(vga_b)
);

// Text controller
text_controller text_ctrl (
    .clk(clk),
    .reset(reset),    
    .device_select(text_select),
    .register_offset(register_offset),
    .write_req(write_req),
    .wdata(wdata),
    .rdata(text_rdata),
    
    .fb_addr(text_fb_addr),
    .fb_data(text_fb_data),
    .fb_write_enable(text_fb_write_enable),
    .fb_read_data(fb_read_data),
    
    .clear_request(text_clear_request),
    .clear_in_progress(clear_pending),
    
    .busy(text_busy)
);

// Graphics controller
graphics_controller graphics_ctrl (
    .clk(clk),
    .reset(reset),    
    .device_select(graphics_select),
    .register_offset(register_offset),
    .write_req(write_req),
    .wdata(wdata),
    .rdata(graphics_rdata),
    
    .fb_addr(graphics_fb_addr),
    .fb_data(graphics_fb_data),
    .fb_write_enable(graphics_fb_write_enable),
    .fb_read_data(fb_read_data),  // Connected for Add mode
    
    .clear_request(graphics_clear_request),
    .clear_in_progress(clear_pending),
    
    .busy(graphics_busy)
);

// Color controller
color_controller color_ctrl (
    .clk(clk),
    .reset(reset),    
    .device_select(color_select),
    .register_offset(register_offset),
    .write_req(write_req),
    .wdata(wdata),
    .rdata(color_rdata),
    
    .fb_addr(color_fb_addr),
    .fb_data(color_fb_data),
    .fb_write_enable(color_fb_write_enable),
    
    .clear_request(color_clear_request),
    .clear_in_progress(color_clear_pending),  // Color clear in progress
    
    .busy(color_busy)
);

// Multiplex frame buffer write signals to appropriate buffer
always_comb begin
    // Default: maintain address for reads, no writes
    fb_a_write_addr = cpu_addr;  // Always provide address for potential reads
    fb_a_write_data = cpu_data;
    fb_a_write_enable = 1'b0;
    fb_b_write_addr = cpu_addr;  // Always provide address for potential reads
    fb_b_write_data = cpu_data;
    fb_b_write_enable = 1'b0;
    
    // Normal operation - write to selected write buffer
    if (write_buffer == 1'b0) begin
        // Write to Buffer A
        fb_a_write_enable = cpu_write_en;
    end else begin
        // Write to Buffer B
        fb_b_write_enable = cpu_write_en;
    end
end

// Desired buffer control
always_comb begin
    desired_buffer = display_buffer;
end

// Frame buffer arbitration - Text has priority, then Graphics, then Color, then other operations
always_comb begin
    if (text_busy) begin
        // Text controller has exclusive access during operations
        cpu_addr = text_fb_addr;
        cpu_data = text_fb_data;
        cpu_write_en = text_fb_write_enable;
    end else if (graphics_busy) begin
        // Graphics controller has access when text is idle
        cpu_addr = graphics_fb_addr;
        cpu_data = graphics_fb_data;
        cpu_write_en = graphics_fb_write_enable;
    end else if (color_busy) begin
        // Color controller has access when text and graphics are idle
        cpu_addr = color_fb_addr;
        cpu_data = color_fb_data;
        cpu_write_en = color_fb_write_enable;
    end else if (clear_pending) begin
        // Pixel clear operations (when text, graphics, and color idle)
        cpu_addr = clear_address;
        cpu_data = 8'h00;
        cpu_write_en = 1'b1;
    end else if (color_clear_pending) begin
        // Color clear operations (bytes 8000-8999)
        cpu_addr = COLOR_DATA_OFFSET + color_clear_address;
        cpu_data = 8'h00;  // Clear to black on black
        cpu_write_en = 1'b1;
    end else if (palette1_write_pending) begin
        // Palette1 writes (bytes 0-1)
        if (!palette1_write_byte1) begin
            cpu_addr = PALETTE_DATA_ADDR;
            cpu_data = palette_choice_bits[7:0];
        end else begin
            cpu_addr = PALETTE_DATA_ADDR + 14'd1;
            cpu_data = palette_choice_bits[15:8];
        end
        cpu_write_en = 1'b1;
    end else if (palette2_write_pending) begin
        // Palette2 writes (bytes 2-3)
        if (!palette2_write_byte3) begin
            cpu_addr = PALETTE_DATA_ADDR + 14'd2;
            cpu_data = palette_choice_bits[23:16];
        end else begin
            cpu_addr = PALETTE_DATA_ADDR + 14'd3;
            cpu_data = {7'h00, palette_choice_bits[24]};
        end
        cpu_write_en = 1'b1;
    end else begin
        // No operations active
        cpu_addr = 14'd0;
        cpu_data = 8'h00;
        cpu_write_en = 1'b0;
    end
end

// Frame buffer busy signal
logic frame_buffer_busy;

// Busy signal is high when any operation is in progress
always_comb begin
    frame_buffer_busy = text_busy ||
                       graphics_busy ||
                       color_busy ||
                       clear_pending ||
                       color_clear_pending ||
                       palette1_write_pending ||
                       palette2_write_pending;
end

// Memory-mapped I/O interface
always_ff @(posedge clk) begin
    if (reset) begin        
        // Common registers
        palette_choice_bits <= 25'h0000000;  // Default: color for all rows
        write_buffer <= 1'b0;                // Default: Write to Buffer A
        display_buffer <= 1'b0;              // Default: Display Buffer A
        
        // Palette update control
        palette1_write_pending <= 1'b0;
        palette1_write_byte1 <= 1'b0;
        palette2_write_pending <= 1'b0;
        palette2_write_byte3 <= 1'b0;
        
        // Clear operation control
        clear_pending <= 1'b0;
        clear_address <= 13'd0;
        
        // Color clear operation control
        color_clear_pending <= 1'b0;
        color_clear_address <= 10'd0;
        
        // Registered read data for timing closure
        rdata_reg <= 16'h0000;
    end else begin     
        // Handle clear requests from text or graphics controllers
        if ((text_clear_request || graphics_clear_request) && !clear_pending && !cpu_write_en) begin
            clear_pending <= 1'b1;
            clear_address <= 13'd0;
        end
        
        // Handle color clear request from color controller
        if (color_clear_request && !color_clear_pending && !cpu_write_en) begin
            color_clear_pending <= 1'b1;
            color_clear_address <= 10'd0;
        end
        
        // Handle clear writes (bytes 0-7999) - when text, graphics, and color not busy
        if (clear_pending && !text_busy && !graphics_busy && !color_busy && !cpu_write_en) begin
            // Advance to next address or complete
            if (clear_address == 13'd7999) begin
                clear_pending <= 1'b0;     // Clear complete
            end else begin
                clear_address <= clear_address + 1;
            end
        end
        // Handle color clear writes (bytes 8000-8999) - when text, graphics, and color not busy
        else if (color_clear_pending && !text_busy && !graphics_busy && !color_busy && !cpu_write_en) begin
            // Advance to next address or complete
            if (color_clear_address == 10'd999) begin
                color_clear_pending <= 1'b0;     // Color clear complete
            end else begin
                color_clear_address <= color_clear_address + 1;
            end
        end
        // Handle palette1 byte writes (bytes 0-1 for bits 0-15)
        else if (palette1_write_pending && !text_busy && !graphics_busy && !color_busy && !cpu_write_en) begin
            if (!palette1_write_byte1) begin
                palette1_write_byte1 <= 1'b1;
            end else begin
                palette1_write_pending <= 1'b0;
                palette1_write_byte1 <= 1'b0;
            end
        end
        // Handle palette2 byte writes (bytes 2-3 for bits 16-24)
        else if (palette2_write_pending && !text_busy && !graphics_busy && !color_busy && !cpu_write_en) begin
            if (!palette2_write_byte3) begin
                palette2_write_byte3 <= 1'b1;
            end else begin
                palette2_write_pending <= 1'b0;
                palette2_write_byte3 <= 1'b0;
            end
        end
        
        // Handle register writes (blocked if frame buffer is busy)
        if ((write_req && device_select) && !cpu_write_en && !text_busy && !graphics_busy && !color_busy) begin
            case (register_offset)
                // Common Interface (not handled by controllers)
                REG_PALETTE_CHOICE_1: begin
                    palette_choice_bits[15:0] <= wdata;
                    // Trigger palette1 update sequence (bytes 0-1)
                    palette1_write_pending <= 1'b1;
                    palette1_write_byte1 <= 1'b0;
                end
                REG_PALETTE_CHOICE_2: begin
                    palette_choice_bits[24:16] <= wdata[8:0];
                    // Trigger palette2 update sequence (bytes 2-3)
                    palette2_write_pending <= 1'b1;
                    palette2_write_byte3 <= 1'b0;
                end
                REG_FLIP_CONTROL: begin
                    write_buffer <= wdata[8];
                    display_buffer <= wdata[9];
                end
                default: begin
                    // Text, Graphics, and Color registers handled by their respective controllers
                end
            endcase
        end  // end if register writes
        
        // Register read interface for timing closure
        if (read_req && device_select) begin
            unique case (register_offset)
                // Text registers (0x0-0x2)
                4'h0, 4'h1, 4'h2: rdata_reg <= text_rdata;
                // Graphics registers (0x5-0x7)
                4'h5, 4'h6, 4'h7: rdata_reg <= graphics_rdata;
                // Common registers
                4'h9: rdata_reg <= {15'h0000, frame_buffer_busy};  // Status register
                4'hA: rdata_reg <= palette_choice_bits[15:0];
                4'hB: rdata_reg <= {7'h00, palette_choice_bits[24:16]};
                4'hC: rdata_reg <= {6'h00, display_buffer, write_buffer, 8'h00};
                // Color registers (0xD-0xF)
                4'hD, 4'hE, 4'hF: rdata_reg <= color_rdata;
                default: rdata_reg <= 16'hFFFF;
            endcase
        end
    end
end

// Connect registered read data to output
assign rdata = rdata_reg;

endmodule
