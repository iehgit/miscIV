module io_controller (
    input  logic        clk,
    input  logic        clk_en,
    input  logic        reset,
    
    // Stage 2: Interface from core
    input  logic [15:0] io_addr,         // I/O address from core
    input  logic [15:0] io_wdata,        // Write data from core
    input  logic        io_read_req,     // Read request from core (is_load && addr[15])
    input  logic        io_write_req,    // Write request from core (is_store && addr[15])
    
    // Stage 3: Interface to core
    output logic [15:0] io_rdata,        // Read data to core
    
    // External I/O connections
    input  logic [15:0] switches,        // Switch inputs
    output logic [15:0] leds,            // LED outputs (renamed to leds_io in top)
    
    // UART Interface
    output logic        uart_tx,         // UART TX pin
    input  logic        uart_rx,         // UART RX pin
    
    // VGA Interface  
    output logic [3:0]  vgaRed, vgaGreen, vgaBlue,  // VGA color outputs
    output logic        Hsync, Vsync,               // VGA sync signals
    
    // Audio I2S Interface (JB Pmod header)
    output logic        audio_mclk,      // Master clock to Pmod
    output logic        audio_lrck,      // L/R word select
    output logic        audio_sclk,      // Serial bit clock
    output logic        audio_sdin,      // Serial data out to DAC
    
    // Quad SPI Flash Interface
    output logic        QspiCSn,         // Chip select for SPI flash
    inout  logic [3:0]  QspiDB           // Quad SPI data lines
);

    // This I/O controller has intentional hazards for timing optimization:
    //
    // READ-AFTER-WRITE HAZARD (1-cycle duration):
    //    - Write in cycle N, read in cycle N+1 may return stale data
    //    - Write executes in Stage 3 of cycle N
    //    - Read sent in Stage 2 of cycle N+1, returns data in Stage 3 of cycle N+1
    //    - Solution: Software must insert 1 NOP between write and read to same device
    //    - Acceptable trade-off for critical path optimization

    // Two-tier addressing scheme: 16 addresses per device
    // Bits [14:4]: Device ID (11 bits = 2048 devices max)
    // Bits [3:0]:  Register offset within device (16 registers per device)
    
    // Device ID assignments (allocated from top of I/O space downward)
    localparam logic [10:0] SIMPLE_IO_DEVICE = 11'h7FF; // Device 2047: 0xFFF0-0xFFFF
    localparam logic [10:0] UART_DEVICE      = 11'h7FE; // Device 2046: 0xFFE0-0xFFEF  
    localparam logic [10:0] VGA_DEVICE       = 11'h7FD; // Device 2045: 0xFFD0-0xFFDF
    localparam logic [10:0] ROM_DEVICE       = 11'h7FC; // Device 2044: 0xFFC0-0xFFCF
    localparam logic [10:0] AUDIO_DEVICE     = 11'h7FB; // Device 2043: 0xFFB0-0xFFBF
    
    // Stage 2->3 pipeline registers
    logic [10:0] device_id_reg;       // Which device (extracted from address)
    logic [3:0]  register_offset_reg; // Which register within device
    logic        read_req_reg;        // Pipelined read request
    logic        write_req_reg;       // Pipelined write request
    logic [15:0] wdata_reg;           // Pipelined write data
    
    // Device controller signals
    logic [15:0] uart_rdata;          // Read data from UART controller
    logic        uart_device_select;  // UART device selected
    logic [15:0] simple_io_rdata;     // Read data from Simple I/O device
    logic        simple_io_device_select; // Simple I/O device selected
    logic [15:0] vga_rdata;           // Read data from VGA/GPU controller
    logic        vga_device_select;   // VGA device selected
    logic [15:0] audio_rdata;         // Read data from Audio controller
    logic        audio_device_select; // Audio device selected
    logic [15:0] rom_rdata;           // Read data from ROM controller
    logic        rom_device_select;   // ROM device selected
    
    // Stage 2: Address field extraction and pipelining
    // Extract device ID and offset
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (reset) begin
                device_id_reg <= 11'd0;
                register_offset_reg <= 4'h0;
                read_req_reg <= 1'b0;
                write_req_reg <= 1'b0;
                wdata_reg <= 16'h0000;
            end else begin
                // Extract address fields (no comparisons needed)
                device_id_reg <= io_addr[14:4];       // Device ID
                register_offset_reg <= io_addr[3:0];  // Register offset within device
                
                // Pipeline control signals and data
                read_req_reg <= io_read_req;
                write_req_reg <= io_write_req;
                wdata_reg <= io_wdata;
            end
        end
    end
    
    // Device selection signals
    assign uart_device_select = (device_id_reg == UART_DEVICE);
    assign simple_io_device_select = (device_id_reg == SIMPLE_IO_DEVICE);
    assign vga_device_select = (device_id_reg == VGA_DEVICE);
    assign audio_device_select = (device_id_reg == AUDIO_DEVICE);
    assign rom_device_select = (device_id_reg == ROM_DEVICE);
    
    // Stage 3: Read data multiplexing using device ID
    always_comb begin
        if (read_req_reg) begin
            unique case (device_id_reg)
                SIMPLE_IO_DEVICE: begin
                    // Simple I/O device reads (Device 2047) - handled by Simple I/O controller
                    io_rdata = simple_io_rdata;
                end
                UART_DEVICE: begin
                    // UART device reads (Device 2046) - handled by UART controller
                    io_rdata = uart_rdata;
                end
                VGA_DEVICE: begin
                    // VGA device reads (Device 2045) - handled by GPU controller
                    io_rdata = vga_rdata;
                end
                ROM_DEVICE: begin
                    // ROM device reads (Device 2044) - handled by ROM controller
                    io_rdata = rom_rdata;
                end
                AUDIO_DEVICE: begin
                    // Audio device reads (Device 2043) - handled by Audio controller
                    io_rdata = audio_rdata;
                end
                default: begin
                    io_rdata = 16'hFFFF;  // Unmapped device (bus pull-ups)
                end
            endcase
        end else begin
            io_rdata = 16'hXXXX;          // No read request active (don't care)
        end
    end
    
    // Simple I/O Device Controller instantiation
    simple_io_device simple_io_device (
        .clk(clk),
        .reset(reset),
        
        // I/O Controller Interface
        .device_select(simple_io_device_select),
        .register_offset(register_offset_reg),
        .read_req(read_req_reg),
        .write_req(write_req_reg),
        .wdata(wdata_reg),
        .rdata(simple_io_rdata),
        
        // External I/O connections
        .switches(switches),
        .leds(leds)
    );
    
    // UART Controller instantiation
    uart_controller uart_controller (
        .clk(clk),
        .reset(reset),
        
        // I/O Controller Interface
        .device_select(uart_device_select),
        .register_offset(register_offset_reg),
        .read_req(read_req_reg),
        .write_req(write_req_reg),
        .wdata(wdata_reg),
        .rdata(uart_rdata),
        
        // UART Interface
        .uart_tx(uart_tx),
        .uart_rx(uart_rx)
    );
    
    // GPU Controller instantiation (includes VGA timing)
    gpu gpu (
        .clk(clk),
        .reset(reset),
        
        // I/O Controller Interface
        .device_select(vga_device_select),
        .register_offset(register_offset_reg),
        .read_req(read_req_reg),
        .write_req(write_req_reg),
        .wdata(wdata_reg),
        .rdata(vga_rdata),
        
        // VGA Interface
        .vga_r(vgaRed),
        .vga_g(vgaGreen),
        .vga_b(vgaBlue),
        .vga_hsync(Hsync),
        .vga_vsync(Vsync)
    );
    
    // Audio Controller instantiation (includes clock wizard)
    audio_controller audio_controller (
        .clk(clk),
        .reset(reset),
        
        // I/O Controller Interface
        .device_select(audio_device_select),
        .register_offset(register_offset_reg),
        .read_req(read_req_reg),
        .write_req(write_req_reg),
        .wdata(wdata_reg),
        .rdata(audio_rdata),
        
        // I2S Interface (JB Pmod header)
        .audio_mclk(audio_mclk),
        .audio_lrck(audio_lrck),
        .audio_sclk(audio_sclk),
        .audio_sdin(audio_sdin)
    );
    
    // ROM Controller instantiation (Quad SPI Flash)
    rom_controller rom_controller (
        .clk(clk),
        .reset(reset),
        
        // I/O Controller Interface
        .device_select(rom_device_select),
        .register_offset(register_offset_reg),
        .read_req(read_req_reg),
        .write_req(write_req_reg),
        .wdata(wdata_reg),
        .rdata(rom_rdata),
        
        // Quad SPI Flash Interface
        .QspiCSn(QspiCSn),
        .QspiDB(QspiDB)
    );

endmodule
