module misc_top (
    // Clock
    input  logic        clk,          // 100MHz system clock
    
    // Switches  
    input  logic [15:0] sw,           // 16 slide switches
    
    // LEDs
    output logic [15:0] led,          // 16 LEDs
    
    // 7-Segment Display
    output logic [6:0]  seg,          // 7-segment segments (a-g)
    output logic        dp,           // Decimal point
    output logic [3:0]  an,           // Anode controls (digit select)
    
    // Buttons
    input  logic        btnR,         // Right button (used as reset)
    input  logic        btnC,         // Center button (speed toggle)
    input  logic        btnL,         // Left button (Altair mode control)
    input  logic        btnU,         // Up button (Altair examine)
    input  logic        btnD,         // Down button (Altair deposit)
    
    // UART Interface
    output logic        RsTx,         // UART TX pin
    input  logic        RsRx,         // UART RX pin
    
    // VGA Interface
    output logic [3:0]  vgaRed,       // VGA red channel
    output logic [3:0]  vgaGreen,     // VGA green channel  
    output logic [3:0]  vgaBlue,      // VGA blue channel
    output logic        Hsync,        // VGA horizontal sync
    output logic        Vsync,        // VGA vertical sync
    
    // Pmod JA Connector (Interrupts)
    input  logic        JA1,          // Pmod JA connector (for high priority interrupt)
    input  logic        JA2,          // Pmod JA connector (for low priority interrupt)
    output logic        JA3,          // Pmod JA connector (for interrupt busy)
    
    // Pmod JB Connector (Audio I2S interface)
    output logic        JB1,          // Audio MCLK (Master clock) - Top row DAC
    output logic        JB2,          // Audio LRCK (L/R word select) - Top row DAC
    output logic        JB3,          // Audio SCLK (Serial bit clock) - Top row DAC
    output logic        JB4,          // Audio SDIN (Serial data to DAC) - Top row DAC
    output logic        JB7,          // Audio MCLK (Master clock) - Bottom row ADC
    output logic        JB8,          // Audio LRCK (L/R word select) - Bottom row ADC
    output logic        JB9,          // Audio SCLK (Serial bit clock) - Bottom row ADC
    // JB10 is SDOUT from ADC, not needed for output-only operation
    
    // Quad SPI Flash Interface
    output logic        QspiCSn,      // Chip select for SPI flash
    inout  logic [3:0]  QspiDB,       // Quad SPI data lines
    
    // PS/2 Keyboard Interface
    input  logic        PS2Clk,       // PS/2 clock from keyboard
    input  logic        PS2Data       // PS/2 data from keyboard
);

    // Speed control signals
    logic speed_toggle = 1'b0;        // 0=100MHz, 1=1Hz (persists through reset)
    logic btnC_pulse;                 // Debounced center button pulse
    logic cpu_clk_en;                 // Final clock enable for CPU core

    // 1Hz generation using cascaded dividers
    logic        slow_clk_en;         // 1Hz enable pulse (~1.00123Hz, 0.123% fast)

    // 7-segment display signals
    logic [15:0] display_value;       // 4 hex digits to display (from CPU)
    logic [15:0] display_value_mux;   // Multiplexed display value
    logic        display_dp_3;        // Decimal point (leftmost) from CPU
    logic        display_dp_2;        // Decimal point from CPU
    logic        display_dp_1;        // Decimal point from CPU
    logic        display_dp_0;        // Decimal point (rightmost) from CPU
    logic        display_dp_3_mux;    // Multiplexed DP3
    logic        display_dp_2_mux;    // Multiplexed DP2
    logic        display_dp_1_mux;    // Multiplexed DP1
    logic        display_dp_0_mux;    // Multiplexed DP0
    logic        debug_dp0;           // Debug signal from CPU
    logic        debug_dp1;           // Debug signal from CPU
    logic        debug_dp2;           // Debug signal from CPU
    logic        debug_dp3;           // Debug signal from CPU

    // I/O Controller Interface (between core and I/O controller)
    logic [15:0] io_addr;             // I/O address from core to controller
    logic [15:0] io_wdata;            // I/O write data from core to controller
    logic        io_read_req;         // I/O read request from core to controller
    logic        io_write_req;        // I/O write request from core to controller
    logic [15:0] io_rdata;            // I/O read data from controller to core
    logic [15:0] leds_from_io;        // LED values from I/O controller

    // Altair mode I/O controller interface
    logic [15:0] io_addr_mux;         // Multiplexed I/O address
    logic [15:0] io_wdata_mux;        // Multiplexed I/O write data
    logic        io_read_req_mux;     // Multiplexed I/O read request
    logic        io_write_req_mux;    // Multiplexed I/O write request

    // Interrupt interface signals
    logic        irq_busy;            // ISR active status from CPU core
    
    logic reset_sync1, reset_sync2;
    logic reset;

    // Altair mode types and states
    typedef enum logic {
        MODE_NORMAL,
        MODE_ALTAIR
    } mode_t;
    
    typedef enum logic [2:0] {
        ALTAIR_IDLE,
        ALTAIR_READ_WAIT,
        ALTAIR_READ_WAIT2,
        ALTAIR_READ_DONE,
        ALTAIR_WRITE,
        ALTAIR_WRITE_DONE
    } altair_op_t;
    
    mode_t cpu_mode = MODE_NORMAL;    // Power-on state is normal mode
    altair_op_t altair_op;

    // Altair mode registers
    logic [15:0] altair_address;      // Current address
    logic        altair_mem_select = 1'b0;   // 0=DMEM/IO, 1=IMEM (initialized)
    logic [15:0] altair_data_display;  // Data for LED display
    
    // Altair memory control signals
    logic        altair_imem_write_en;
    logic        altair_dmem_write_en;
    logic        altair_io_read_en;
    logic        altair_io_write_en;

    // Button debouncing signals
    logic btnL_short_pulse, btnL_long_pulse;
    logic btnU_pulse, btnD_pulse;

    // Memory interface signals from CPU
    logic [13:0] cpu_imem_addr;
    logic        cpu_imem_branch_override;
    logic [13:0] cpu_imem_branch_target;
    logic [15:0] cpu_imem_data;
    logic [13:0] cpu_imem_data_addr;
    
    logic [14:0] cpu_dmem_raddr;
    logic [14:0] cpu_dmem_waddr;
    logic [15:0] cpu_dmem_wdata;
    logic        cpu_dmem_we;
    logic [15:0] cpu_dmem_rdata;

    // Memory interface signals for multiplexing
    logic [13:0] imem_next_raddr_mux;
    logic        imem_branch_override_mux;
    logic [13:0] imem_branch_target_mux;
    logic        imem_altair_we;
    logic [13:0] imem_altair_waddr;
    logic [15:0] imem_altair_wdata;
    
    logic [14:0] dmem_raddr_mux;
    logic [14:0] dmem_waddr_mux;
    logic [15:0] dmem_wdata_mux;
    logic        dmem_we_mux;
    
    // Memory clock enables
    logic imem_clk_en, dmem_clk_en;

    // 2-stage reset synchronizer
    always_ff @(posedge clk) begin
        if (btnR) begin
            reset_sync1 <= 1'b1;
            reset_sync2 <= 1'b1;
        end else begin
            reset_sync1 <= 1'b0;
            reset_sync2 <= reset_sync1;
        end
    end

    assign reset = reset_sync2;

    // Connect interrupt status to Pmod JA connector
    assign JA3 = irq_busy;          // ISR active output for external monitoring

    // Connect debug signals to decimal points (before multiplexing)
    assign display_dp_3 = debug_dp3;   // Available for future debug signal
    assign display_dp_2 = debug_dp2;   // Available for future debug signal  
    assign display_dp_1 = debug_dp1;   // Show ISR active status
    assign display_dp_0 = debug_dp0;   // Show instruction NOPed signal

    // Speed toggle logic (separate from main reset)
    always_ff @(posedge clk) begin
        if (btnC_pulse) begin
            speed_toggle <= ~speed_toggle;  // Toggle between 100MHz and 1Hz
        end
        // Note: speed_toggle is NOT reset by btnR (persists through CPU reset)
    end

    // 1Hz clock enable generation
    pulse_generator pulse_generator (
        .clk(clk),
        .reset(reset),
        .pulse_out(slow_clk_en)
    );

    // Clock enable selection - CPU paused during Altair mode
    assign cpu_clk_en = (cpu_mode == MODE_ALTAIR) ? 1'b0 : 
                       ((speed_toggle ? slow_clk_en : 1'b1) | reset);

    // Memory clock enables - always run at full speed in Altair mode
    assign imem_clk_en = (cpu_mode == MODE_NORMAL) ? cpu_clk_en : 1'b1;
    assign dmem_clk_en = (cpu_mode == MODE_NORMAL) ? cpu_clk_en : 1'b1;

    // Button debouncers
    debouncer btnC_debouncer (
        .clk(clk),
        .btn_in(btnC),
        .pulse_out(btnC_pulse)
    );
    
    // BTNL with long press detection for Altair mode control
    debouncer_long btnL_debouncer_long (
        .clk(clk),
        .btn_in(btnL),
        .pulse_out(btnL_short_pulse),
        .long_pulse_out(btnL_long_pulse)
    );
    
    // BTNU for Altair examine
    debouncer btnU_debouncer (
        .clk(clk),
        .btn_in(btnU),
        .pulse_out(btnU_pulse)
    );
    
    // BTND for Altair deposit
    debouncer btnD_debouncer (
        .clk(clk),
        .btn_in(btnD),
        .pulse_out(btnD_pulse)
    );

    // Altair mode control state machine
    always_ff @(posedge clk) begin
        // Mode control is NOT reset by btnR - persists through reset
        // Entry via short press BTNL, exit via long press BTNL
        
        if (cpu_mode == MODE_NORMAL) begin
            if (btnL_short_pulse) begin
                cpu_mode <= MODE_ALTAIR;
            end
        end else begin  // MODE_ALTAIR
            if (btnL_long_pulse) begin
                cpu_mode <= MODE_NORMAL;
            end
        end
    end

    // Altair operation sequencer and memory select control
    always_ff @(posedge clk) begin
        if (reset) begin
            altair_op <= ALTAIR_IDLE;
            altair_imem_write_en <= 1'b0;
            altair_dmem_write_en <= 1'b0;
            altair_io_read_en <= 1'b0;
            altair_io_write_en <= 1'b0;
            // Note: altair_address persists through reset
        end else begin
            // Default: clear single-cycle control signals
            altair_imem_write_en <= 1'b0;
            altair_dmem_write_en <= 1'b0;
            altair_io_read_en <= 1'b0;
            altair_io_write_en <= 1'b0;
            
            if (cpu_mode == MODE_NORMAL && btnL_short_pulse) begin
                // Initialize when entering Altair mode
                altair_mem_select <= 1'b0;  // Start with DMEM/IO
                altair_op <= ALTAIR_IDLE;
            end else if (cpu_mode == MODE_ALTAIR) begin
                case (altair_op)
                    ALTAIR_IDLE: begin
                        if (btnU_pulse) begin
                            // EXAMINE: Load address from switches and read
                            altair_address <= sw;
                            altair_op <= ALTAIR_READ_WAIT;
                            // Set read enables based on address and selection
                            if (!altair_mem_select && sw[15]) begin  // Use sw directly since address not latched yet
                                altair_io_read_en <= 1'b1;
                            end
                        end else if (btnD_pulse) begin
                            // DEPOSIT: Write data from switches
                            altair_op <= ALTAIR_WRITE;
                        end else if (btnL_short_pulse) begin
                            // Toggle memory selection
                            altair_mem_select <= ~altair_mem_select;
                        end
                    end
                    
                    ALTAIR_READ_WAIT: begin
                        // Wait for read to complete
                        if (altair_mem_select) begin
                            // IMEM needs extra cycle for address pipeline
                            altair_op <= ALTAIR_READ_WAIT2;
                        end else begin
                            // DMEM/IO can proceed directly
                            altair_op <= ALTAIR_READ_DONE;
                        end
                    end
                    
                    ALTAIR_READ_WAIT2: begin
                        // Extra wait state for IMEM pipeline
                        altair_op <= ALTAIR_READ_DONE;
                    end
                    
                    ALTAIR_READ_DONE: begin
                        // Capture read data to LEDs
                        if (altair_mem_select) begin
                            altair_data_display <= cpu_imem_data;  // From IMEM
                        end else if (!altair_address[15]) begin
                            altair_data_display <= cpu_dmem_rdata;  // From DMEM
                        end else begin
                            altair_data_display <= io_rdata;    // From I/O
                        end
                        altair_op <= ALTAIR_IDLE;
                    end
                    
                    ALTAIR_WRITE: begin
                        // Execute write based on address/selection
                        if (altair_mem_select) begin
                            altair_imem_write_en <= 1'b1;
                        end else if (!altair_address[15]) begin
                            altair_dmem_write_en <= 1'b1;
                        end else begin
                            altair_io_write_en <= 1'b1;
                        end
                        altair_data_display <= sw;  // Show what was written
                        altair_op <= ALTAIR_WRITE_DONE;
                    end
                    
                    ALTAIR_WRITE_DONE: begin
                        // Auto-increment address
                        altair_address <= altair_address + 1;
                        altair_op <= ALTAIR_IDLE;
                    end
                endcase
            end
        end
    end

    // LED output multiplexer
    always_comb begin
        if (cpu_mode == MODE_ALTAIR) begin
            led = altair_data_display;  // Show Altair mode data
        end else begin
            led = leds_from_io;  // Show normal I/O controller LEDs
        end
    end

    // Display value and DP multiplexing
    always_comb begin
        if (cpu_mode == MODE_ALTAIR) begin
            display_value_mux = altair_address;
            display_dp_3_mux = altair_mem_select;   // 1=IMEM selected
            display_dp_2_mux = ~altair_mem_select;  // 1=DMEM/IO selected
            display_dp_1_mux = 1'b0;
            display_dp_0_mux = 1'b0;
        end else begin
            display_value_mux = display_value;  // PC from CPU
            display_dp_3_mux = display_dp_3;    // Debug from CPU
            display_dp_2_mux = display_dp_2;    // Debug from CPU
            display_dp_1_mux = display_dp_1;    // ISR busy from CPU
            display_dp_0_mux = display_dp_0;    // Instruction NOPed from CPU
        end
    end

    // IMEM interface multiplexing
    always_comb begin
        if (cpu_mode == MODE_ALTAIR && altair_mem_select) begin
            // Altair mode IMEM access
            imem_next_raddr_mux = altair_address[13:0];  // Use lower 14 bits
            imem_branch_override_mux = 1'b0;
            imem_branch_target_mux = 14'd0;
            imem_altair_we = altair_imem_write_en;
            imem_altair_waddr = altair_address[13:0];
            imem_altair_wdata = sw;  // Direct from switches
        end else begin
            // Normal CPU access
            imem_next_raddr_mux = cpu_imem_addr;
            imem_branch_override_mux = cpu_imem_branch_override;
            imem_branch_target_mux = cpu_imem_branch_target;
            imem_altair_we = 1'b0;
            imem_altair_waddr = 14'd0;
            imem_altair_wdata = 16'h0000;
        end
    end

    // DMEM interface multiplexing
    always_comb begin
        if (cpu_mode == MODE_ALTAIR && !altair_mem_select && !altair_address[15]) begin
            // Altair mode DMEM access (address bit 15 = 0)
            dmem_raddr_mux = altair_address[14:0];
            dmem_waddr_mux = altair_address[14:0];
            dmem_wdata_mux = sw;
            dmem_we_mux = altair_dmem_write_en;
        end else begin
            // Normal CPU access
            dmem_raddr_mux = cpu_dmem_raddr;
            dmem_waddr_mux = cpu_dmem_waddr;
            dmem_wdata_mux = cpu_dmem_wdata;
            dmem_we_mux = cpu_dmem_we;
        end
    end

    // I/O Controller interface multiplexing
    always_comb begin
        if (cpu_mode == MODE_ALTAIR && !altair_mem_select && altair_address[15]) begin
            // Altair mode I/O access (address bit 15 = 1)
            io_addr_mux = altair_address;
            io_wdata_mux = sw;
            io_read_req_mux = altair_io_read_en;
            io_write_req_mux = altair_io_write_en;
        end else begin
            // Normal CPU access
            io_addr_mux = io_addr;
            io_wdata_mux = io_wdata;
            io_read_req_mux = io_read_req;
            io_write_req_mux = io_write_req;
        end
    end
    
    // CPU Core (with external memory interfaces)
    misc_core #(
        .IMEMW(14)                       // 14-bit imem addressing (16K words)
    ) misc_core (
        .clk(clk),
        .clk_en(cpu_clk_en),             // Clock enable input
        .reset(reset),                   // Reset signal
        
        // Interrupt Interface
        .irq_request(JA1),               // Direct connection to JA1
        .irq2_request(JA2),              // Direct connection to JA2
        .irq_busy(irq_busy),             // ISR active status output
        
        // IMEM interface
        .imem_addr(cpu_imem_addr),
        .imem_branch_override(cpu_imem_branch_override),
        .imem_branch_target(cpu_imem_branch_target),
        .imem_data(cpu_imem_data),
        .imem_data_addr(cpu_imem_data_addr),
        
        // DMEM interface
        .dmem_raddr(cpu_dmem_raddr),
        .dmem_waddr(cpu_dmem_waddr),
        .dmem_wdata(cpu_dmem_wdata),
        .dmem_we(cpu_dmem_we),
        .dmem_rdata(cpu_dmem_rdata),
        
        // I/O Controller Interface
        .io_addr(io_addr),               // I/O address to controller
        .io_wdata(io_wdata),             // I/O write data to controller
        .io_read_req(io_read_req),       // I/O read request to controller
        .io_write_req(io_write_req),     // I/O write request to controller
        .io_rdata(io_rdata),             // I/O read data from controller
        
        // Debug outputs
        .pc_display(display_value),
        .dp0(debug_dp0),                 // Debug: instruction NOPed signal
        .dp1(debug_dp1),                 // Debug: interrupt busy signal
        .dp2(debug_dp2),                 // Debug: available for future use
        .dp3(debug_dp3)                  // Debug: available for future use
    );
    
    // Instruction Memory (BRAM) with Altair write support
    imem #(
        .ADDR_WIDTH(14),
        .INIT_FILE("imem.mem")
    ) imem (
        .clk(clk),
        .clk_en(imem_clk_en),
        .next_raddr(imem_next_raddr_mux),
        .branch_override(imem_branch_override_mux),
        .branch_target_addr(imem_branch_target_mux),
        .data_out(cpu_imem_data),
        .addr_out(cpu_imem_data_addr),
        // Altair mode write port
        .altair_we(imem_altair_we),
        .altair_waddr(imem_altair_waddr),
        .altair_wdata(imem_altair_wdata)
    );
    
    // Data Memory (BRAM)
    dmem #(
        .ADDR_WIDTH(15),
        .INIT_FILE("dmem.mem")
    ) dmem (
        .clk(clk),
        .clk_en(dmem_clk_en),
        .raddr(dmem_raddr_mux),
        .waddr(dmem_waddr_mux),
        .wdata(dmem_wdata_mux),
        .we(dmem_we_mux),
        .rdata(cpu_dmem_rdata)
    );
    
    // I/O Controller (handles all memory-mapped I/O devices including ROM and Keyboard)
    io_controller io_controller (
        .clk(clk),
        .clk_en(cpu_clk_en),             // Same clock enable as core
        .reset(reset),                   // Same reset as core
        
        // Interface from/to core (Stage 2->3 pipeline)
        .io_addr(io_addr_mux),           // Multiplexed I/O address
        .io_wdata(io_wdata_mux),         // Multiplexed I/O write data
        .io_read_req(io_read_req_mux),   // Multiplexed I/O read request
        .io_write_req(io_write_req_mux), // Multiplexed I/O write request
        .io_rdata(io_rdata),             // I/O read data (used by both modes)
        
        // External I/O connections
        .switches(sw),                   // Switch inputs from top-level
        .leds(leds_from_io),             // LED outputs
        
        // UART Interface
        .uart_tx(RsTx),                  // UART TX pin
        .uart_rx(RsRx),                  // UART RX pin
        
        // VGA Interface
        .vgaRed(vgaRed),                 // VGA red channel
        .vgaGreen(vgaGreen),             // VGA green channel
        .vgaBlue(vgaBlue),               // VGA blue channel
        .Hsync(Hsync),                   // VGA horizontal sync
        .Vsync(Vsync),                   // VGA vertical sync
        
        // Audio I2S Interface (JB Pmod header)
        .audio_mclk(JB1),                // Master clock to Pmod (top row DAC)
        .audio_lrck(JB2),                // L/R word select (top row DAC)
        .audio_sclk(JB3),                // Serial bit clock (top row DAC)
        .audio_sdin(JB4),                // Serial data to DAC (top row)
        
        // Quad SPI Flash Interface
        .QspiCSn(QspiCSn),               // Chip select for SPI flash
        .QspiDB(QspiDB),                 // Quad SPI data lines
        
        // PS/2 Keyboard Interface
        .PS2Clk(PS2Clk),                // PS/2 clock from keyboard
        .PS2Data(PS2Data)               // PS/2 data from keyboard
    );
    
    // Connect same clock signals to bottom row for ADC
    // The Pmod I2S2 requires clocks on both rows even if only using DAC
    assign JB7 = JB1;  // MCLK to bottom row ADC
    assign JB8 = JB2;  // LRCK to bottom row ADC
    assign JB9 = JB3;  // SCLK to bottom row ADC
    
    // 7-Segment Display Driver (always at full speed for smooth multiplexing)
    sevenseg_driver sevenseg_driver (
        .clk(clk),                   // No clock enable - always full speed
        .value(display_value_mux),   // Multiplexed value
        .dp_3(display_dp_3_mux),     // Multiplexed DP3
        .dp_2(display_dp_2_mux),     // Multiplexed DP2
        .dp_1(display_dp_1_mux),     // Multiplexed DP1
        .dp_0(display_dp_0_mux),     // Multiplexed DP0
        .reset(reset),
        .an(an),
        .seg(seg),
        .dp(dp)
    );

endmodule
