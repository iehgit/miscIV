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
    localparam logic [3:0] REG_ROM_BANK   = 4'h1;  // Bank selector [3:0]
    localparam logic [3:0] REG_ROM_DATA   = 4'h2;  // Read data
    localparam logic [3:0] REG_ROM_STATUS = 4'h3;  // Status (bit 0 = valid)
    
    // SPI Commands
    localparam logic [7:0] CMD_FAST_READ_QUAD_IO = 8'hEB;  // Fast Read Quad I/O
    
    // Timeout value (32 cycles @ 50MHz = 0.64us)
    localparam logic [4:0] TIMEOUT_CYCLES = 5'd31;
    
    // State machine states
    typedef enum logic [4:0] {
        IDLE,
        SEND_CMD,
        SEND_ADDR5,
        SEND_ADDR4,
        SEND_ADDR3,
        SEND_ADDR2,
        SEND_ADDR1,
        SEND_ADDR0,
        SEND_MODE1,
        SEND_MODE0,
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
    logic [3:0]  rom_bank_reg;        // Bank selector register (16 banks of 128KB each)
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
    logic [3:0]  dq_output_en;        // Output enables for each DQ pin
    
    // State machine counters and control
    logic [2:0]  bit_counter;         // Bit counter for serial transmission
    logic [1:0]  dummy_counter;       // Counter for dummy cycles (reduced to 4)
    logic [4:0]  timeout_counter;     // Timeout detection
    
    // Data assembly
    logic [7:0]  cmd_shift_reg;       // Command shift register
    logic [23:0] addr_value;          // Full address to send
    
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
        .T(~dq_output_en[0])    // 3-state control (1=input, 0=output)
    );
    
    IOBUF iobuf_dq1 (
        .O(dq_in[1]),           // Buffer output (from pad)
        .IO(QspiDB[1]),         // Buffer inout port (connect to top-level port)
        .I(dq_out[1]),          // Buffer input (data to drive out)
        .T(~dq_output_en[1])    // 3-state control (1=input, 0=output)
    );
    
    IOBUF iobuf_dq2 (
        .O(dq_in[2]),           // Buffer output (from pad)
        .IO(QspiDB[2]),         // Buffer inout port (connect to top-level port)
        .I(dq_out[2]),          // Buffer input (data to drive out)
        .T(~dq_output_en[2])    // 3-state control (1=input, 0=output)
    );
    
    IOBUF iobuf_dq3 (
        .O(dq_in[3]),           // Buffer output (from pad)
        .IO(QspiDB[3]),         // Buffer inout port (connect to top-level port)
        .I(dq_out[3]),          // Buffer input (data to drive out)
        .T(~dq_output_en[3])    // 3-state control (1=input, 0=output)
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
            if ((state == DUMMY_WAIT && dummy_counter == 2'd3) ||  // Last dummy cycle
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
            rom_bank_reg <= 4'h0;
            read_triggered <= 1'b0;
        end else begin
            read_triggered <= 1'b0;  // Default: clear trigger
            
            // Bank register write (does NOT trigger read)
            if (device_select && write_req && register_offset == REG_ROM_BANK) begin
                rom_bank_reg <= wdata[3:0];  // Only use lower 4 bits for 16 banks
            end
            
            // Address register write (triggers read)
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
                    next_state = SEND_ADDR5;
                end
            end
            
            SEND_ADDR5: next_state = SEND_ADDR4;
            SEND_ADDR4: next_state = SEND_ADDR3;
            SEND_ADDR3: next_state = SEND_ADDR2;
            SEND_ADDR2: next_state = SEND_ADDR1;
            SEND_ADDR1: next_state = SEND_ADDR0;
            SEND_ADDR0: next_state = SEND_MODE1;
            SEND_MODE1: next_state = SEND_MODE0;
            SEND_MODE0: next_state = DUMMY_WAIT;
            
            DUMMY_WAIT: begin
                if (dummy_counter == 2'd3) begin
                    next_state = READ_NIBBLE0;
                end
            end
            
            READ_NIBBLE0: next_state = READ_NIBBLE1;
            READ_NIBBLE1: next_state = READ_NIBBLE2;
            READ_NIBBLE2: next_state = READ_NIBBLE3;
            READ_NIBBLE3: next_state = DONE;
            
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
            dq_output_en <= 4'h0;
            bit_counter <= 3'd0;
            dummy_counter <= 2'd0;
            timeout_counter <= 5'd0;
            cmd_shift_reg <= 8'h00;
            addr_value <= 24'h000000;
            rom_data_reg <= 16'h0000;
            data_valid <= 1'b0;
        end else if (spi_clk_en) begin
            unique case (state)
                IDLE: begin
                    cs_n <= 1'b1;
                    dq_output_en <= 4'h0;
                    bit_counter <= 3'd0;
                    dummy_counter <= 2'd0;
                    timeout_counter <= 5'd0;
                    data_valid <= 1'b0;
                    
                    if (read_triggered) begin
                        // Prepare for new transaction
                        cs_n <= 1'b0;  // Assert chip select
                        cmd_shift_reg <= CMD_FAST_READ_QUAD_IO;
                        // Calculate flash address based on bank:
                        // [23:17] = 0x10 + bank (0x10 = 2MB base / 128KB)
                        // Bank 0: 0x10 (0x200000), Bank 1: 0x11 (0x220000), etc.
                        // [16:1]  = rom_addr_reg (16-bit word address)
                        // [0]     = 1'b0 (even byte address for word alignment)
                        addr_value <= {(7'h10 + {3'b000, rom_bank_reg}), rom_addr_reg, 1'b0};
                        dq_output_en <= 4'h1;  // Enable only DQ0 for command
                    end
                end
                
                SEND_CMD: begin
                    // Send command byte on DQ0 (MSB first)
                    dq_out[0] <= cmd_shift_reg[7];
                    cmd_shift_reg <= {cmd_shift_reg[6:0], 1'b0};
                    bit_counter <= bit_counter + 1;
                    timeout_counter <= timeout_counter + 1;
                    
                    if (bit_counter == 3'd7) begin
                        dq_output_en <= 4'hF;  // Enable all DQ pins for address phase
                    end
                end
                
                // Send address nibbles in quad mode (6 cycles total)
                SEND_ADDR5: begin
                    dq_out <= addr_value[23:20];  // Send highest nibble
                    timeout_counter <= timeout_counter + 1;
                end
                
                SEND_ADDR4: begin
                    dq_out <= addr_value[19:16];
                    timeout_counter <= timeout_counter + 1;
                end
                
                SEND_ADDR3: begin
                    dq_out <= addr_value[15:12];
                    timeout_counter <= timeout_counter + 1;
                end
                
                SEND_ADDR2: begin
                    dq_out <= addr_value[11:8];
                    timeout_counter <= timeout_counter + 1;
                end
                
                SEND_ADDR1: begin
                    dq_out <= addr_value[7:4];
                    timeout_counter <= timeout_counter + 1;
                end
                
                SEND_ADDR0: begin
                    dq_out <= addr_value[3:0];  // Send lowest nibble
                    timeout_counter <= timeout_counter + 1;
                end
                
                // Send mode bits (0xF0 for continuous quad mode)
                SEND_MODE1: begin
                    dq_out <= 4'hF;  // Upper nibble of mode
                    timeout_counter <= timeout_counter + 1;
                end
                
                SEND_MODE0: begin
                    dq_out <= 4'h0;  // Lower nibble of mode
                    timeout_counter <= timeout_counter + 1;
                    dq_output_en <= 4'h0;  // Switch all DQ to input for data phase
                end
                
                DUMMY_WAIT: begin
                    // 4 dummy cycles required for Fast Read Quad I/O
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
                    timeout_counter <= 5'd0;
                end
                
                ERROR: begin
                    cs_n <= 1'b1;  // Deassert chip select on error
                    dq_output_en <= 4'h0;
                    data_valid <= 1'b0;  // Clear valid flag on error
                    timeout_counter <= 5'd0;
                end
                
                default: begin
                    cs_n <= 1'b1;
                    dq_output_en <= 4'h0;
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
                REG_ROM_BANK: begin
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
