module rom_controller (
    input  logic        clk,          // 100MHz system clock
    input  logic        reset,
    
    // I/O Controller Interface
    input  logic        device_select,
    input  logic [3:0]  register_offset,
    input  logic        read_req,
    input  logic        write_req,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,
    
    // Quad SPI Flash Interface
    output logic        QspiCSn,      // Chip select (active low)
    inout  logic [3:0]  QspiDB        // Quad data lines
);

    // Register offsets
    localparam logic [3:0] REG_ROM_ADDR   = 4'h0;  // Write triggers read
    localparam logic [3:0] REG_ROM_DATA   = 4'h1;  // Read data
    localparam logic [3:0] REG_ROM_STATUS = 4'h2;  // Status (bit 0 = valid)
    
    // SPI Commands
    localparam logic [7:0] CMD_FAST_READ_QUAD = 8'h6B;  // Fast Read Quad Output
    
    // Timeout value (64 cycles @ 50MHz = 1.28us)
    localparam logic [5:0] TIMEOUT_CYCLES = 6'd63;
    
    // State machine states
    typedef enum logic [3:0] {
        IDLE,
        SEND_CMD,
        SEND_ADDR2,
        SEND_ADDR1,
        SEND_ADDR0,
        DUMMY_WAIT,
        READ_NIBBLE0,
        READ_NIBBLE1,
        READ_NIBBLE2,
        READ_NIBBLE3,
        DONE,
        ERROR
    } state_t;
    
    state_t state, next_state;
    
    // Registers
    logic [15:0] rom_addr_reg;        // Address register
    logic [15:0] rom_data_reg;        // Data register
    logic        data_valid;          // Data valid flag
    logic        read_triggered;      // Read operation triggered
    
    // SPI clock generation (50MHz from 100MHz)
    logic        clk_divider;         // Toggle flip-flop
    logic        spi_clk_en;          // 50MHz enable pulse
    logic        spi_clk_out;         // Clock to STARTUPE2
    
    // SPI interface signals
    logic        cs_n;                // Internal chip select
    logic [3:0]  dq_out;              // Data output to flash
    logic [3:0]  dq_in;               // Data input from flash (from IOBUFs)
    logic [3:0]  dq_in_sampled;       // Sampled input data
    logic        dq0_output_en;       // Output enable for DQ0
    
    // State machine counters and control
    logic [2:0]  bit_counter;         // Bit counter for serial transmission
    logic [2:0]  dummy_counter;       // Counter for dummy cycles
    logic [5:0]  timeout_counter;     // Timeout detection
    
    // Data assembly
    logic [7:0]  cmd_shift_reg;       // Command shift register
    logic [23:0] addr_shift_reg;      // Address shift register
    
    // STARTUPE2 primitive for SPI clock routing
    // Dummy signals to suppress synthesis warnings about unconnected outputs
    logic startupe2_cfgclk, startupe2_cfgmclk, startupe2_eos, startupe2_preq;
    
    STARTUPE2 #(
        .PROG_USR("FALSE"),
        .SIM_CCLK_FREQ(10.0)
    ) startupe2_inst (
        .CFGCLK(startupe2_cfgclk),       // Configuration clock output (unused)
        .CFGMCLK(startupe2_cfgmclk),     // Configuration M clock output (unused)
        .EOS(startupe2_eos),             // End of Startup output (unused)
        .PREQ(startupe2_preq),           // Program request output (unused)
        .CLK(1'b0),
        .GSR(1'b0),
        .GTS(1'b0),
        .KEYCLEARB(1'b1),
        .PACK(1'b0),
        .USRCCLKO(spi_clk_out),      // User clock output to SPI flash
        .USRCCLKTS(1'b0),            // 0 = User clock active
        .USRDONEO(1'b1),             // 1 = Configuration done
        .USRDONETS(1'b0)             // 0 = DONE pin active driver
    );
    
    // Clock divider for 50MHz SPI clock
    always_ff @(posedge clk) begin
        if (reset) begin
            clk_divider <= 1'b0;
        end else begin
            clk_divider <= ~clk_divider;
        end
    end
    
    // Generate 50MHz enable pulse and gated SPI clock
    assign spi_clk_en = clk_divider;
    assign spi_clk_out = (state != IDLE && state != DONE && state != ERROR) ? clk_divider : 1'b0;
    
    // Tri-state I/O management - using explicit IOBUFs for all pins for consistency
    assign QspiCSn = cs_n;
    
    // Explicit IOBUF primitives for all SPI data pins
    IOBUF iobuf_dq0 (
        .O(dq_in[0]),           // Buffer output (from pad)
        .IO(QspiDB[0]),         // Buffer inout port (connect to top-level port)
        .I(dq_out[0]),          // Buffer input (data to drive out)
        .T(~dq0_output_en)      // 3-state control (1=input, 0=output)
    );
    
    IOBUF iobuf_dq1 (
        .O(dq_in[1]),           // Buffer output (from pad)
        .IO(QspiDB[1]),         // Buffer inout port (connect to top-level port)
        .I(1'b0),               // Buffer input (unused - always 0)
        .T(1'b1)                // 3-state control (always 1 = input mode)
    );
    
    IOBUF iobuf_dq2 (
        .O(dq_in[2]),           // Buffer output (from pad)
        .IO(QspiDB[2]),         // Buffer inout port (connect to top-level port)
        .I(1'b0),               // Buffer input (unused - always 0)
        .T(1'b1)                // 3-state control (always 1 = input mode)
    );
    
    IOBUF iobuf_dq3 (
        .O(dq_in[3]),           // Buffer output (from pad)
        .IO(QspiDB[3]),         // Buffer inout port (connect to top-level port)
        .I(1'b0),               // Buffer input (unused - always 0)
        .T(1'b1)                // 3-state control (always 1 = input mode)
    );
    
    // Input sampling - sample just before state transition for stable data
    always_ff @(posedge clk) begin
        // Sample on the cycle before spi_clk_en when data is stable
        // This is when clk_divider is low (SPI clock is low, data stable)
        if (!clk_divider) begin
            // Sample one state BEFORE we need the data:
            // - During DUMMY_WAIT: sample what will be used in READ_NIBBLE0
            // - During READ_NIBBLE0: sample what will be used in READ_NIBBLE1
            // - During READ_NIBBLE1: sample what will be used in READ_NIBBLE2
            // - During READ_NIBBLE2: sample what will be used in READ_NIBBLE3
            if ((state == DUMMY_WAIT && dummy_counter == 3'd7) ||  // Last dummy cycle
                 state == READ_NIBBLE0 ||
                 state == READ_NIBBLE1 ||
                 state == READ_NIBBLE2) begin
                dq_in_sampled <= dq_in;  // Sample data from IOBUF outputs
            end
        end
    end
    
    // Register write interface
    always_ff @(posedge clk) begin
        if (reset) begin
            rom_addr_reg <= 16'h0000;
            read_triggered <= 1'b0;
        end else begin
            read_triggered <= 1'b0;  // Default: clear trigger
            
            if (device_select && write_req && register_offset == REG_ROM_ADDR) begin
                rom_addr_reg <= wdata;
                read_triggered <= 1'b1;  // Trigger read operation
            end
        end
    end
    
    // State machine - sequential
    always_ff @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
        end else if (spi_clk_en) begin
            state <= next_state;
        end
    end
    
    // State machine - combinational next state logic
    always_comb begin
        next_state = state;
        
        unique case (state)
            IDLE: begin
                if (read_triggered) begin
                    next_state = SEND_CMD;
                end
            end
            
            SEND_CMD: begin
                if (bit_counter == 3'd7) begin
                    next_state = SEND_ADDR2;
                end
            end
            
            SEND_ADDR2: begin
                if (bit_counter == 3'd7) begin
                    next_state = SEND_ADDR1;
                end
            end
            
            SEND_ADDR1: begin
                if (bit_counter == 3'd7) begin
                    next_state = SEND_ADDR0;
                end
            end
            
            SEND_ADDR0: begin
                if (bit_counter == 3'd7) begin
                    next_state = DUMMY_WAIT;
                end
            end
            
            DUMMY_WAIT: begin
                if (dummy_counter == 3'd7) begin
                    next_state = READ_NIBBLE0;
                end
            end
            
            READ_NIBBLE0: begin
                next_state = READ_NIBBLE1;
            end
            
            READ_NIBBLE1: begin
                next_state = READ_NIBBLE2;
            end
            
            READ_NIBBLE2: begin
                next_state = READ_NIBBLE3;
            end
            
            READ_NIBBLE3: begin
                next_state = DONE;
            end
            
            DONE: begin
                next_state = IDLE;
            end
            
            ERROR: begin
                if (!read_triggered) begin  // Wait for new transaction to clear error
                    next_state = IDLE;
                end
            end
            
            default: begin
                next_state = IDLE;
            end
        endcase
        
        // Timeout detection (across all active states)
        if (state != IDLE && state != DONE && state != ERROR) begin
            if (timeout_counter == TIMEOUT_CYCLES) begin
                next_state = ERROR;
            end
        end
    end
    
    // State machine operations
    always_ff @(posedge clk) begin
        if (reset) begin
            cs_n <= 1'b1;              // Chip select inactive
            dq_out <= 4'h0;
            dq0_output_en <= 1'b0;
            bit_counter <= 3'd0;
            dummy_counter <= 3'd0;
            timeout_counter <= 6'd0;
            cmd_shift_reg <= 8'h00;
            addr_shift_reg <= 24'h000000;
            rom_data_reg <= 16'h0000;
            data_valid <= 1'b0;
        end else if (spi_clk_en) begin
            unique case (state)
                IDLE: begin
                    cs_n <= 1'b1;
                    dq0_output_en <= 1'b0;
                    bit_counter <= 3'd0;
                    dummy_counter <= 3'd0;
                    timeout_counter <= 6'd0;
                    data_valid <= 1'b0;
                    
                    if (read_triggered) begin
                        // Prepare for new transaction
                        cs_n <= 1'b0;  // Assert chip select
                        cmd_shift_reg <= CMD_FAST_READ_QUAD;
                        // Direct bit concatenation for flash address:
                        // [23:17] = 7'b0000001 (2MB offset = 0x200000)
                        // [16:1]  = rom_addr_reg (16-bit word address)
                        // [0]     = 1'b0 (even byte address for word alignment)
                        addr_shift_reg <= {7'b0000001, rom_addr_reg, 1'b0};
                        dq0_output_en <= 1'b1;  // Enable output for command
                    end
                end
                
                SEND_CMD: begin
                    // Send command byte on DQ0 (MSB first)
                    dq_out[0] <= cmd_shift_reg[7];
                    cmd_shift_reg <= {cmd_shift_reg[6:0], 1'b0};
                    bit_counter <= bit_counter + 1;
                    timeout_counter <= timeout_counter + 1;
                end
                
                SEND_ADDR2: begin
                    // Send address[23:16] on DQ0
                    dq_out[0] <= addr_shift_reg[23];
                    addr_shift_reg <= {addr_shift_reg[22:0], 1'b0};
                    bit_counter <= bit_counter + 1;
                    timeout_counter <= timeout_counter + 1;
                end
                
                SEND_ADDR1: begin
                    // Send address[15:8] on DQ0
                    dq_out[0] <= addr_shift_reg[23];
                    addr_shift_reg <= {addr_shift_reg[22:0], 1'b0};
                    bit_counter <= bit_counter + 1;
                    timeout_counter <= timeout_counter + 1;
                end
                
                SEND_ADDR0: begin
                    // Send address[7:0] on DQ0
                    dq_out[0] <= addr_shift_reg[23];
                    addr_shift_reg <= {addr_shift_reg[22:0], 1'b0};
                    bit_counter <= bit_counter + 1;
                    timeout_counter <= timeout_counter + 1;
                    
                    if (bit_counter == 3'd7) begin
                        dq0_output_en <= 1'b0;  // Switch DQ0 to input for data phase
                    end
                end
                
                DUMMY_WAIT: begin
                    // 8 dummy cycles required for Fast Read Quad
                    dummy_counter <= dummy_counter + 1;
                    timeout_counter <= timeout_counter + 1;
                end
                
                READ_NIBBLE0: begin
                    // Read bits [3:0] of the word (first nibble of low byte)
                    rom_data_reg[3:0] <= dq_in_sampled;
                    timeout_counter <= timeout_counter + 1;
                end
                
                READ_NIBBLE1: begin
                    // Read bits [7:4] of the word (second nibble of low byte)
                    rom_data_reg[7:4] <= dq_in_sampled;
                    timeout_counter <= timeout_counter + 1;
                end
                
                READ_NIBBLE2: begin
                    // Read bits [11:8] of the word (first nibble of high byte)
                    rom_data_reg[11:8] <= dq_in_sampled;
                    timeout_counter <= timeout_counter + 1;
                end
                
                READ_NIBBLE3: begin
                    // Read bits [15:12] of the word (second nibble of high byte)
                    rom_data_reg[15:12] <= dq_in_sampled;
                    timeout_counter <= timeout_counter + 1;
                end
                
                DONE: begin
                    cs_n <= 1'b1;  // Deassert chip select
                    data_valid <= 1'b1;  // Mark data as valid
                    timeout_counter <= 6'd0;
                end
                
                ERROR: begin
                    cs_n <= 1'b1;  // Deassert chip select on error
                    dq0_output_en <= 1'b0;
                    data_valid <= 1'b0;  // Clear valid flag on error
                    timeout_counter <= 6'd0;
                end
                
                default: begin
                    cs_n <= 1'b1;
                    dq0_output_en <= 1'b0;
                end
            endcase
        end
    end
    
    // Register read interface
    always_comb begin
        rdata = 16'hXXXX;  // Default: don't care
        
        if (device_select && read_req) begin
            unique case (register_offset)
                REG_ROM_ADDR: begin
                    rdata = 16'hFFFF;  // Write-only register
                end
                REG_ROM_DATA: begin
                    rdata = rom_data_reg;  // Return fetched data
                end
                REG_ROM_STATUS: begin
                    rdata = {15'h0000, data_valid};  // Bit 0 = data valid
                end
                default: begin
                    rdata = 16'hFFFF;  // Unmapped registers
                end
            endcase
        end
    end

endmodule
