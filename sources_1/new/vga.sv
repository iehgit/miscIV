module vga (
    input  logic        clk,              // 100MHz system clock
    
    // Frame buffer A write interface (from parent GPU, 100MHz domain)
    input  logic [13:0] fb_a_write_addr,   // Frame buffer A write address
    input  logic [7:0]  fb_a_write_data,   // Frame buffer A write data  
    input  logic        fb_a_write_enable, // Frame buffer A write enable
    output logic [7:0]  fb_a_read_data,    // Frame buffer A read data (NEW)
    
    // Frame buffer B write interface (from parent GPU, 100MHz domain)
    input  logic [13:0] fb_b_write_addr,   // Frame buffer B write address
    input  logic [7:0]  fb_b_write_data,   // Frame buffer B write data
    input  logic        fb_b_write_enable, // Frame buffer B write enable
    output logic [7:0]  fb_b_read_data,    // Frame buffer B read data (NEW)
    
    // Display control interface (from parent GPU, 100MHz domain)
    input  logic        desired_buffer,    // 0=Buffer A, 1=Buffer B
    
    // VGA output signals (directly from 25MHz domain)
    output logic        hsync,            // Horizontal sync  
    output logic        vsync,            // Vertical sync
    
    // VGA color outputs (directly from 25MHz domain)
    output logic [3:0]  vga_r, vga_g, vga_b
);

// VGA 640×400@70Hz timing parameters
// Pixel clock: 25.173MHz from clock wizard
localparam H_ACTIVE     = 640;   // Active video width
localparam H_FRONT      = 16;    // Front porch  
localparam H_SYNC       = 96;    // Sync pulse width
localparam H_BACK       = 48;    // Back porch
localparam H_TOTAL      = H_ACTIVE + H_FRONT + H_SYNC + H_BACK; // 800

localparam V_ACTIVE     = 400;   // Active video height  
localparam V_FRONT      = 12;    // Front porch
localparam V_SYNC       = 2;     // Sync pulse width  
localparam V_BACK       = 35;    // Back porch
localparam V_TOTAL      = V_ACTIVE + V_FRONT + V_SYNC + V_BACK; // 449

// Frame buffer parameters
localparam FRAME_WIDTH = 320;
localparam FRAME_HEIGHT = 200;
localparam BYTES_PER_FRAME = 8000;      // 320*200/8 = 8000 bytes (pixel data)
localparam COLOR_CELLS_X = 40;          // 320/8 = 40 cells horizontally
localparam COLOR_CELLS_Y = 25;          // 200/8 = 25 cells vertically
localparam COLOR_DATA_OFFSET = 8000;    // Color data starts at byte 8000
localparam BYTES_PER_COLOR = 1000;      // 40*25 = 1000 color cells
localparam PALETTE_DATA_ADDR = 9000;    // Start of 4-byte packed palette data
localparam TOTAL_BYTES = 9004;          // 8000 pixel + 1000 color + 4 palette bytes
localparam ADDR_WIDTH = 14;             // 2^14 = 16384 bytes
localparam MEMORY_SIZE = 72032;         // 9004 * 8 bits
localparam ROW_INIT_START = 793;        // When to start Row FSM initialization (2 cycles earlier)

// Clock wizard instance
logic vga_clk;
clk_wiz_0 clk_wiz_inst (
    .clk_out1(vga_clk),    // 25.175MHz output
    .clk_in1(clk)          // 100MHz input
);

//=============================================================================
// TDP BRAM FRAME BUFFERS (PING-PONG) - EXPANDED FOR COLOR DATA
//=============================================================================

// BRAM control signals
logic [13:0] read_addr_vga;
logic read_enable_vga;

// BRAM read outputs
logic [7:0] frame_data_a, frame_data_b;

// True Dual Port BRAM for Buffer A (expanded for color data)
xpm_memory_tdpram #(
    .ADDR_WIDTH_A(ADDR_WIDTH),           // 14 bits - GPU address
    .ADDR_WIDTH_B(ADDR_WIDTH),           // 14 bits - VGA address  
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(8),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("independent_clock"), // Critical: independent clocks
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("frame.mem"),
    .MEMORY_INIT_PARAM(""),             // Initialize to zeros
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("auto"),           // Let Xilinx choose BRAM36
    .MEMORY_SIZE(MEMORY_SIZE),           // 72,032 bits
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_A(8),
    .READ_DATA_WIDTH_B(8),
    .READ_LATENCY_A(1),                  // 1 cycle read latency
    .READ_LATENCY_B(1),                  // 1 cycle read latency
    .READ_RESET_VALUE_A("0"),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(1),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(8),
    .WRITE_MODE_A("read_first"),         // Read-first mode for GPU port
    .WRITE_MODE_B("read_first")          // Read-first mode for VGA port
) tdp_buffer_a (
    // Port A: GPU read/write interface (100MHz domain)
    .clka(clk),                          // 100MHz system clock
    .addra(fb_a_write_addr),             // Direct from GPU
    .dina(fb_a_write_data),              // Direct from GPU
    .douta(fb_a_read_data),              // Read data to GPU (NEW)
    .ena(1'b1),
    .wea(fb_a_write_enable),             // Direct from GPU
    .regcea(1'b1),                       // Enable output register
    .rsta(1'b0),                         // No reset
    .injectsbiterra(1'b0),               // No error injection
    .injectdbiterra(1'b0),
    
    // Port B: VGA read interface (25MHz domain)  
    .clkb(vga_clk),                      // 25MHz VGA clock
    .addrb(read_addr_vga),               // Read address
    .dinb(8'h00),                        // VGA never writes
    .doutb(frame_data_a),                // Read data for VGA
    .enb(read_enable_vga),               // Read enable
    .web(1'b0),                          // VGA never writes
    .regceb(1'b1),                       // Enable output register
    .rstb(1'b0),                         // No reset
    .injectsbiterrb(1'b0),               // No error injection
    .injectdbiterrb(1'b0)
);

// True Dual Port BRAM for Buffer B (expanded for color data)
xpm_memory_tdpram #(
    .ADDR_WIDTH_A(ADDR_WIDTH),           // 14 bits - GPU address
    .ADDR_WIDTH_B(ADDR_WIDTH),           // 14 bits - VGA address  
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(8),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("independent_clock"), // Critical: independent clocks
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("frame.mem"),
    .MEMORY_INIT_PARAM(""),              // Initialize to zeros
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("auto"),           // Let Xilinx choose BRAM36
    .MEMORY_SIZE(MEMORY_SIZE),           // 72,032 bits
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_A(8),
    .READ_DATA_WIDTH_B(8),
    .READ_LATENCY_A(1),                  // 1 cycle read latency
    .READ_LATENCY_B(1),                  // 1 cycle read latency
    .READ_RESET_VALUE_A("0"),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(1),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(8),
    .WRITE_MODE_A("read_first"),         // Read-first mode for GPU port
    .WRITE_MODE_B("read_first")          // Read-first mode for VGA port
) tdp_buffer_b (
    // Port A: GPU read/write interface (100MHz domain)
    .clka(clk),                          // 100MHz system clock
    .addra(fb_b_write_addr),             // Direct from GPU
    .dina(fb_b_write_data),              // Direct from GPU
    .douta(fb_b_read_data),              // Read data to GPU (NEW)
    .ena(1'b1),
    .wea(fb_b_write_enable),             // Direct from GPU
    .regcea(1'b1),                       // Enable output register
    .rsta(1'b0),                         // No reset
    .injectsbiterra(1'b0),               // No error injection
    .injectdbiterra(1'b0),
    
    // Port B: VGA read interface (25MHz domain)  
    .clkb(vga_clk),                      // 25MHz VGA clock
    .addrb(read_addr_vga),               // Read address
    .dinb(8'h00),                        // VGA never writes
    .doutb(frame_data_b),                // Read data for VGA
    .enb(read_enable_vga),               // Read enable
    .web(1'b0),                          // VGA never writes
    .regceb(1'b1),                       // Enable output register
    .rstb(1'b0),                         // No reset
    .injectsbiterrb(1'b0),               // No error injection
    .injectdbiterrb(1'b0)
);

//=============================================================================
// MINIMAL CDC FOR DISPLAY CONTROL ONLY
//=============================================================================

// CDC for display control only
(* ASYNC_REG = "TRUE" *) logic [1:0] desired_buffer_sync;
logic active_buffer;  // 0 = Buffer A active (display), 1 = Buffer B active
logic current_palette_mode;  // 0 = Color palette, 1 = Grayscale palette (per row)

// Simple synchronizer for buffer selection
always_ff @(posedge vga_clk) begin
    desired_buffer_sync <= {desired_buffer_sync[0], desired_buffer};
end

//=============================================================================
// VGA CLOCK DOMAIN (25.175MHz) - SCREEN COORDINATES ONLY
//=============================================================================

// VGA domain counters - SINGLE SOURCE OF TRUTH
logic [9:0] h_count_vga;  // 0-639 screen pixels
logic [9:0] v_count_vga;  // 0-399 screen scanlines

// VGA horizontal timing
always_ff @(posedge vga_clk) begin
    if (h_count_vga == H_TOTAL - 1) begin
        h_count_vga <= 10'd0;
    end else begin
        h_count_vga <= h_count_vga + 1;
    end
end

// VGA vertical timing
always_ff @(posedge vga_clk) begin
    if (h_count_vga == H_TOTAL - 1) begin
        if (v_count_vga == V_TOTAL - 1) begin
            v_count_vga <= 10'd0;
        end else begin
            v_count_vga <= v_count_vga + 1;
        end
    end
end

// Generate sync pulses (negative polarity)
always_ff @(posedge vga_clk) begin
    hsync <= ~((h_count_vga >= (H_ACTIVE + H_FRONT)) && 
               (h_count_vga < (H_ACTIVE + H_FRONT + H_SYNC)));

    vsync <= ~((v_count_vga >= (V_ACTIVE + V_FRONT)) && 
               (v_count_vga < (V_ACTIVE + V_FRONT + V_SYNC)));
end

// Video active generation
logic video_active_vga;
always_ff @(posedge vga_clk) begin
    video_active_vga <= (h_count_vga < H_ACTIVE) && (v_count_vga < V_ACTIVE);
end

//=============================================================================
// DUAL FSM ARCHITECTURE
//=============================================================================

// Row FSM - handles initialization and pipeline for every scanline independently  
typedef enum logic [2:0] {
    ROW_INIT_READ_PALETTE,      // Issue read for palette byte
    ROW_INIT_WAIT_PALETTE,      // Wait for BRAM latency, extract palette bit
    ROW_INIT_READ_PIXEL,        // Issue read for first pixel byte of row
    ROW_INIT_WAIT_PIXEL,        // Wait for BRAM latency, register pixel data
    ROW_INIT_READ_COLOR,        // Issue read for first color byte of row  
    ROW_INIT_WAIT_COLOR,        // Wait for BRAM latency, register color data
    ROW_INIT_PRIME,             // Prime the pipeline for group 0 display
    ROW_PIPELINE                // Pipeline: display current, load next sequentially
} row_state_t;

row_state_t row_state;

//=============================================================================
// ADDRESS CALCULATION FROM SCREEN COORDINATES
//=============================================================================

// Convert screen coordinates to framebuffer addresses
logic [8:0] logical_x;      // h_count_vga / 2
logic [7:0] logical_y;      // v_count_vga / 2 (or next row during init)
logic [9:0] next_v_count;   // For address calculation during Row FSM init
logic [15:0] pixel_addr;    // logical_y * 320 + logical_x
logic [13:0] pixel_byte_addr; // pixel_addr / 8

logic [5:0] cell_x;         // logical_x / 8
logic [4:0] cell_y;         // logical_y / 8  
logic [13:0] color_addr;    // COLOR_DATA_OFFSET + (cell_y * 40 + cell_x)
logic [5:0] cell_x_next;    // Next group's cell_x for pipeline reads
logic [13:0] color_addr_next; // Next group's color address

// Palette address calculation
logic [4:0] color_cell_row;     // Which color cell row (0-24)
logic [13:0] palette_byte_addr; // Address for palette byte
logic [2:0] palette_bit_index;  // Which bit within the byte (0-7)

// Address calculation - handle next row during Row FSM initialization
always_comb begin   
    // During Row FSM initialization (795-799), use coordinates for group 0 of next row
    if (h_count_vga >= 795) begin
        logical_x = 9'd0;                   // First group (x = 0) of next row
        if (v_count_vga == V_TOTAL - 1) begin
            // Wraparound: last line prepares for first line
            logical_y = 8'd0;
        end else begin
            next_v_count = v_count_vga + 1;
            logical_y = next_v_count[8:1];  // Next row's logical_y
        end
    end else begin
        logical_x = h_count_vga[9:1];       // Current screen position
        logical_y = v_count_vga[8:1];       // Current row's logical_y
    end
    
    pixel_addr = logical_y * FRAME_WIDTH + logical_x;
    pixel_byte_addr = pixel_addr[15:3];     // / 8 for byte addressing
    
    cell_x = logical_x[8:3];                // logical_x / 8 (0-39)
    cell_y = logical_y[7:3];                // logical_y / 8 (0-24)
    color_addr = COLOR_DATA_OFFSET + (cell_y * COLOR_CELLS_X + cell_x);
    
    // Calculate palette address for this color cell row
    color_cell_row = logical_y[7:3];        // Same as cell_y (0-24)
    palette_byte_addr = PALETTE_DATA_ADDR + (color_cell_row >> 3);  // Which byte (0-3)
    palette_bit_index = color_cell_row[2:0]; // Which bit within byte (0-7)
    
    // Calculate next group's color address for pipeline reads (same row only)
    cell_x_next = cell_x + 1;
    color_addr_next = COLOR_DATA_OFFSET + (cell_y * COLOR_CELLS_X + cell_x_next);
end

//=============================================================================
// PIPELINE REGISTERS AND COUNTERS
//=============================================================================

// Pixel counter: 0-15 (each bit read twice)
logic [3:0] pixel_bit_counter;
logic [2:0] bit_index;

// Pipeline data registers
logic [7:0] current_pixel_byte;     // Currently being displayed
logic [7:0] next_pixel_byte;        // Being loaded for next group
logic [3:0] current_fg_color, current_bg_color;  // Current colors
logic [3:0] next_fg_color, next_bg_color;        // Next group colors

// Bit index calculation (which bit 0-7 within the byte)
always_comb begin
    bit_index = h_count_vga[3:1];           // Which bit (0-7) in pixel byte (wraps every group)
    pixel_bit_counter = h_count_vga[3:0];   // 0-15 counter
end

//=============================================================================
// BUFFER SWITCHING LOGIC
//=============================================================================

logic vsync_prev;

// Simple buffer switching without FSM
always_ff @(posedge vga_clk) begin
    vsync_prev <= vsync;
    
    // Switch buffer on VSYNC if different from desired
    if (vsync && !vsync_prev && (desired_buffer_sync[1] != active_buffer)) begin
        active_buffer <= desired_buffer_sync[1];
    end
end

//=============================================================================
// ROW FSM IMPLEMENTATION - EVERY SCANLINE INDEPENDENT
//=============================================================================

always_ff @(posedge vga_clk) begin
    // Row FSM triggered during back porch before each video active line
    if (h_count_vga == ROW_INIT_START && v_count_vga != V_ACTIVE - 1) begin
        row_state <= ROW_INIT_READ_PALETTE;
    end else if (video_active_vga || row_state != ROW_PIPELINE) begin
        case (row_state)
            ROW_INIT_READ_PALETTE: begin
                row_state <= ROW_INIT_WAIT_PALETTE;
            end
            ROW_INIT_WAIT_PALETTE: begin
                // Extract palette bit for this color cell row (1 cycle after read)
                if (active_buffer == 1'b0) begin
                    current_palette_mode <= frame_data_a[palette_bit_index];
                end else begin
                    current_palette_mode <= frame_data_b[palette_bit_index];
                end
                row_state <= ROW_INIT_READ_PIXEL;
            end
            ROW_INIT_READ_PIXEL: begin
                row_state <= ROW_INIT_WAIT_PIXEL;
            end
            ROW_INIT_WAIT_PIXEL: begin
                // Register first pixel byte (1 cycle after read)
                if (active_buffer == 1'b0) begin
                    current_pixel_byte <= frame_data_a;
                end else begin
                    current_pixel_byte <= frame_data_b;
                end
                row_state <= ROW_INIT_READ_COLOR;
            end
            ROW_INIT_READ_COLOR: begin
                row_state <= ROW_INIT_WAIT_COLOR;
            end
            ROW_INIT_WAIT_COLOR: begin
                // Register first color data (1 cycle after read)
                if (active_buffer == 1'b0) begin
                    current_fg_color <= frame_data_a[7:4];
                    current_bg_color <= frame_data_a[3:0];
                end else begin
                    current_fg_color <= frame_data_b[7:4];
                    current_bg_color <= frame_data_b[3:0];
                end
                row_state <= ROW_INIT_PRIME;
            end
            ROW_INIT_PRIME: begin
                // All preparation complete - ready for seamless pipeline
                row_state <= ROW_PIPELINE;
            end
            ROW_PIPELINE: begin
                // Pipeline operation
                if (video_active_vga) begin
                    case (pixel_bit_counter)
                        4'h3: begin
                            // Register next pixel data (1 cycle after read at 4'h2)
                            if (active_buffer == 1'b0) begin
                                next_pixel_byte <= frame_data_a;
                            end else begin
                                next_pixel_byte <= frame_data_b;
                            end
                        end
                        4'h5: begin
                            // Register next color data (1 cycle after read at 4'h4)
                            if (active_buffer == 1'b0) begin
                                next_fg_color <= frame_data_a[7:4];
                                next_bg_color <= frame_data_a[3:0];
                            end else begin
                                next_fg_color <= frame_data_b[7:4];
                                next_bg_color <= frame_data_b[3:0];
                            end
                        end
                        4'hF: begin
                            // Promote both pixel and color data at end of group
                            current_pixel_byte <= next_pixel_byte;
                            current_fg_color <= next_fg_color;
                            current_bg_color <= next_bg_color;
                        end
                    endcase
                end
            end
        endcase
    end
end

//=============================================================================
// BRAM READ CONTROL
//=============================================================================

always_comb begin
    case (row_state)
        ROW_INIT_READ_PALETTE: begin
            // Read palette byte for this color cell row
            read_addr_vga = palette_byte_addr;
            read_enable_vga = 1'b1;
        end
        ROW_INIT_READ_PIXEL: begin
            // Read first pixel byte of row
            read_addr_vga = pixel_byte_addr;
            read_enable_vga = 1'b1;
        end
        ROW_INIT_READ_COLOR: begin
            // Read first color byte of row
            read_addr_vga = color_addr;
            read_enable_vga = 1'b1;
        end
        ROW_PIPELINE: begin
            // Pipeline reads for next group (only during video active)
            if (video_active_vga) begin
                case (pixel_bit_counter)
                    4'h2: begin
                        // Issue read for next group pixel data
                        read_addr_vga = pixel_byte_addr + 1;
                        read_enable_vga = 1'b1;
                    end
                    4'h4: begin
                        // Issue read for next group color data
                        read_addr_vga = color_addr_next;
                        read_enable_vga = 1'b1;
                    end
                    default: begin
                        read_addr_vga = 14'd0;
                        read_enable_vga = 1'b0;
                    end
                endcase
            end else begin
                read_addr_vga = 14'd0;
                read_enable_vga = 1'b0;
            end
        end
        default: begin
            read_addr_vga = 14'd0;
            read_enable_vga = 1'b0;
        end
    endcase
end

//=============================================================================
// PIXEL DATA EXTRACTION AND COLOR OUTPUT
//=============================================================================

// Bit reversal using direct wiring
logic [7:0] reversed_pixel_byte;
assign reversed_pixel_byte = {current_pixel_byte[0], current_pixel_byte[1], 
                             current_pixel_byte[2], current_pixel_byte[3], 
                             current_pixel_byte[4], current_pixel_byte[5], 
                             current_pixel_byte[6], current_pixel_byte[7]};
                             
// Auto-contrast and color selection
logic [3:0] final_fg_color, final_bg_color;

// Color selection (registered for synchronized timing with promotion)
logic [3:0] selected_color;
logic [11:0] current_rgb;

always_ff @(posedge vga_clk) begin
    selected_color <= reversed_pixel_byte[bit_index] ? final_fg_color : final_bg_color;
end

// 16-Color Palettes (Standard VGA Colors) - 12-bit RGB (4 bits per channel)
logic [11:0] color_palette [0:15];
logic [11:0] grayscale_palette [0:15];

// Initialize color palette
initial begin
    color_palette[0]  = 12'h000; // Black
    color_palette[1]  = 12'h008; // Dark Blue  
    color_palette[2]  = 12'h080; // Dark Green
    color_palette[3]  = 12'h088; // Dark Cyan
    color_palette[4]  = 12'h800; // Dark Red
    color_palette[5]  = 12'h808; // Dark Magenta
    color_palette[6]  = 12'h880; // Brown
    color_palette[7]  = 12'hCCC; // Light Gray
    color_palette[8]  = 12'h888; // Dark Gray
    color_palette[9]  = 12'h00F; // Bright Blue
    color_palette[10] = 12'h0F0; // Bright Green
    color_palette[11] = 12'h0FF; // Bright Cyan
    color_palette[12] = 12'hF00; // Bright Red
    color_palette[13] = 12'hF0F; // Bright Magenta
    color_palette[14] = 12'hFF0; // Yellow
    color_palette[15] = 12'hFFF; // White
end

// Initialize grayscale palette
initial begin
    grayscale_palette[0]  = 12'h000; // Black
    grayscale_palette[1]  = 12'h222; // Dark Gray
    grayscale_palette[2]  = 12'h333; // Medium Dark Gray  
    grayscale_palette[3]  = 12'h444; // Medium Gray
    grayscale_palette[4]  = 12'h333; // Medium Dark Gray
    grayscale_palette[5]  = 12'h444; // Medium Gray
    grayscale_palette[6]  = 12'h555; // Medium Gray
    grayscale_palette[7]  = 12'hCCC; // Light Gray
    grayscale_palette[8]  = 12'h888; // Dark Gray
    grayscale_palette[9]  = 12'h555; // Medium Gray
    grayscale_palette[10] = 12'h999; // Light Gray
    grayscale_palette[11] = 12'hAAA; // Light Gray
    grayscale_palette[12] = 12'h555; // Medium Gray
    grayscale_palette[13] = 12'hAAA; // Light Gray
    grayscale_palette[14] = 12'hEEE; // Very Light Gray
    grayscale_palette[15] = 12'hFFF; // White
end

always_comb begin
    // Auto-contrast: if foreground equals background, invert foreground
    if (current_fg_color == current_bg_color) begin
        final_fg_color = ~current_fg_color;
        final_bg_color = current_bg_color;
    end else begin
        final_fg_color = current_fg_color;
        final_bg_color = current_bg_color;
    end
    
    // Select palette based on current row's palette mode
    if (current_palette_mode == 1'b0) begin
        current_rgb = color_palette[selected_color];     // Color mode
    end else begin
        current_rgb = grayscale_palette[selected_color]; // Grayscale mode
    end
end

// VGA color output generation
always_ff @(posedge vga_clk) begin
    if (video_active_vga) begin
        // Within video active area - output color from palette
        vga_r <= current_rgb[11:8];  // Red channel
        vga_g <= current_rgb[7:4];   // Green channel  
        vga_b <= current_rgb[3:0];   // Blue channel
    end else begin
        // Outside video active - output black
        vga_r <= 4'h0;
        vga_g <= 4'h0;
        vga_b <= 4'h0;
    end
end

endmodule
