module color_controller (
    input  logic        clk,
    input  logic        reset,
    
    // Memory-mapped register interface (color registers only: 0xD-0xF)
    input  logic        device_select,      // Pre-qualified for color registers
    input  logic [3:0]  register_offset,   
    input  logic        write_req,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,
    
    // Frame buffer interface (generic - main module handles A/B selection)
    output logic [13:0] fb_addr,
    output logic [7:0]  fb_data,
    output logic        fb_write_enable,
    
    // Clear operation interface
    output logic        clear_request,      // Request color clear operation
    input  logic        clear_in_progress,  // Main module performing clear
    
    // Status
    output logic        busy                // Color operations in progress
);

// Frame buffer parameters (same as main module)
localparam COLOR_DATA_OFFSET = 8000;    // Color data starts at byte 8000
localparam COLOR_CELLS_X = 40;          // 40 color cells horizontally
localparam COLOR_CELLS_Y = 25;          // 25 color cells vertically

// Color register addresses
localparam REG_COLOR_VALUES = 4'hD;       // Color cell fg/bg values
localparam REG_COLOR_COORDINATES = 4'hE;  // Color cell coordinates
localparam REG_COLOR_CONTROL = 4'hF;      // Color cell control

// Color registers
logic [15:0] color_values_reg;       // Fg/bg nibbles in upper byte
logic [15:0] color_coordinates_reg;  // X(5:0), Y(12:8)

// Color write operation signals
logic        color_write_pending;    // Color write operation active (single cycle)
logic [13:0] color_cell_addr;        // Calculated color cell address
logic [7:0]  color_cell_data;        // Color data to write

// Clear request handling
logic clear_request_reg;
assign clear_request = clear_request_reg;

// Busy signal - true when color write operation is in progress
assign busy = color_write_pending;

// Main sequential logic
always_ff @(posedge clk) begin
    if (reset) begin
        // Color registers
        color_values_reg <= 16'h0000;
        color_coordinates_reg <= 16'h0000;
        
        // Color write operation
        color_write_pending <= 1'b0;
        color_cell_addr <= 14'd0;
        color_cell_data <= 8'h00;
        
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
        
        // Handle color write operation (single cycle)
        if (color_write_pending) begin
            // Perform the write
            fb_addr <= color_cell_addr;
            fb_data <= color_cell_data;
            fb_write_enable <= 1'b1;
            color_write_pending <= 1'b0;  // Clear pending flag after write
        end
        
        // Handle register writes (blocked if busy or clear in progress)
        if ((write_req && device_select) && !busy && !clear_in_progress) begin
            case (register_offset)
                REG_COLOR_VALUES: begin
                    color_values_reg <= wdata;
                end
                REG_COLOR_COORDINATES: begin
                    color_coordinates_reg <= wdata;
                end
                REG_COLOR_CONTROL: begin
                    if (wdata[8]) begin  // PutColor bit
                        // Calculate color cell address and prepare data
                        automatic logic [5:0] color_x;
                        automatic logic [4:0] color_y;
                        color_x = color_coordinates_reg[5:0];   // X (0-39)
                        color_y = color_coordinates_reg[12:8];  // Y (0-24)
                        
                        // Validate coordinates
                        if (color_x < COLOR_CELLS_X && color_y < COLOR_CELLS_Y) begin
                            color_cell_addr <= COLOR_DATA_OFFSET + (color_y * COLOR_CELLS_X + color_x);
                            color_cell_data <= color_values_reg[15:8];  // Upper byte: fg->[7:4], bg->[3:0]
                            color_write_pending <= 1'b1;
                        end
                        // else: invalid coordinates, ignore
                    end
                    if (wdata[11]) begin  // Clear bit
                        // Request color clear operation from main module
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
            REG_COLOR_VALUES: begin
                rdata = color_values_reg;
            end
            REG_COLOR_COORDINATES: begin
                rdata = color_coordinates_reg;
            end
            REG_COLOR_CONTROL: begin
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
