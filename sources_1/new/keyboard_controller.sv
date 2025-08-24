module keyboard_controller (
    input  logic        clk,          // 100MHz system clock
    input  logic        reset,
    
    // I/O Controller Interface
    input  logic        device_select,
    input  logic [3:0]  register_offset,
    input  logic        read_req,
    input  logic        write_req,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,
    
    // PS/2 Interface
    input  logic        PS2Clk,       // PS/2 clock from keyboard
    input  logic        PS2Data       // PS/2 data from keyboard
);

    // ========================================================================
    // Dual-FIFO Keyboard Controller with ASCII Translation
    // ========================================================================
    // This controller provides two independent data paths:
    //
    // 1. Raw FIFO: Stores all PS/2 scan codes (make/break, extended, etc.)
    //    - For software that needs low-level keyboard access
    //    - Captures all keyboard events including special keys
    //
    // 2. ASCII FIFO: Stores only translated ASCII characters
    //    - For text input applications
    //    - Automatically handles shift state for uppercase/symbols
    //    - Filters out non-printable keys
    //
    // Both FIFOs are 8-entry deep and can be cleared simultaneously
    // ========================================================================
    
    // ========================================================================
    // Register Map:
    // ========================================================================
    // 0xFFA0 (REG_KBD_ASCII):   Read ASCII character (0 if buffer empty)
    // 0xFFA1 (REG_KBD_RAW):     Read raw scan code (0 if buffer empty)
    // 0xFFA2 (REG_KBD_STATUS):  Status register
    //                           [0] = Raw data available
    //                           [1] = Raw FIFO full
    //                           [2] = Raw FIFO overflow
    //                           [3] = ASCII data available
    //                           [4] = ASCII FIFO full
    //                           [5] = ASCII FIFO overflow
    //                           [15:6] = Reserved
    // 0xFFA3 (REG_KBD_CONTROL): Control register (write-only)
    //                           [0] = Clear both FIFOs
    //                           [15:1] = Reserved
    // ========================================================================

    // Register offsets
    localparam logic [3:0] REG_KBD_ASCII   = 4'h0;  // ASCII character from ASCII FIFO
    localparam logic [3:0] REG_KBD_RAW     = 4'h1;  // Raw scan code from Raw FIFO
    localparam logic [3:0] REG_KBD_STATUS  = 4'h2;  // Status register
    localparam logic [3:0] REG_KBD_CONTROL = 4'h3;  // Control register (bit 0 = clear FIFOs)
    
    // Timeout value (10,000 cycles = 100μs @ 100MHz)
    localparam logic [13:0] TIMEOUT_CYCLES = 14'd10000;
    
    // PS/2 signal synchronization (3-stage for metastability)
    logic ps2_clk_sync1, ps2_clk_sync2, ps2_clk_sync3;
    logic ps2_data_sync1, ps2_data_sync2, ps2_data_sync3;
    logic ps2_clk_falling;
    
    // Frame decoder state machine
    typedef enum logic [3:0] {
        IDLE,
        START_BIT,
        DATA_BIT_0,
        DATA_BIT_1,
        DATA_BIT_2,
        DATA_BIT_3,
        DATA_BIT_4,
        DATA_BIT_5,
        DATA_BIT_6,
        DATA_BIT_7,
        PARITY_BIT,
        STOP_BIT,
        VALIDATE
    } ps2_state_t;
    
    ps2_state_t ps2_state, ps2_next_state;
    
    // Frame decoder signals
    logic [7:0]  shift_reg;           // Data byte being received
    logic        parity_bit;          // Received parity bit
    logic        stop_bit;            // Received stop bit
    logic [13:0] timeout_counter;     // Timeout for incomplete frames
    logic        frame_valid;         // Frame passed validation
    logic        parity_valid;        // Parity check result
    
    //=========================================================================
    // Raw Scan Code FIFO
    //=========================================================================
    logic [7:0]  raw_fifo_mem [0:7];      // FIFO memory
    logic [2:0]  raw_fifo_write_ptr;      // Write pointer
    logic [2:0]  raw_fifo_read_ptr;       // Read pointer
    logic [3:0]  raw_fifo_count;          // Number of entries (0-8)
    logic        raw_fifo_write;          // Write strobe from frame decoder
    logic        raw_fifo_read;           // Read strobe from register interface
    logic        raw_fifo_empty;          // FIFO empty flag
    logic        raw_fifo_full;           // FIFO full flag
    logic        raw_fifo_overflow;       // Overflow occurred
    logic [7:0]  raw_fifo_read_data;      // Data at read pointer
    
    //=========================================================================
    // ASCII Translator Signals
    //=========================================================================
    logic [6:0]  translator_ascii_code;   // ASCII output from translator
    logic        translator_ascii_valid;  // Valid ASCII produced
    
    //=========================================================================
    // ASCII FIFO
    //=========================================================================
    logic [7:0]  ascii_fifo_mem [0:7];    // Store as 8-bit (MSB=0 for 7-bit ASCII)
    logic [2:0]  ascii_fifo_write_ptr;    // Write pointer
    logic [2:0]  ascii_fifo_read_ptr;     // Read pointer
    logic [3:0]  ascii_fifo_count;        // Number of entries (0-8)
    logic        ascii_fifo_write;        // Write strobe from translator
    logic        ascii_fifo_read;         // Read strobe from register interface
    logic        ascii_fifo_empty;        // FIFO empty flag
    logic        ascii_fifo_full;         // FIFO full flag
    logic        ascii_fifo_overflow;     // Overflow occurred
    logic [7:0]  ascii_fifo_read_data;    // Data at read pointer
    
    // Control signals
    logic        clear_fifos;             // Clear both FIFOs command
    
    //=========================================================================
    // PS/2 Signal Synchronization and Edge Detection
    //=========================================================================
    
    always_ff @(posedge clk) begin
        if (reset) begin
            ps2_clk_sync1 <= 1'b1;
            ps2_clk_sync2 <= 1'b1;
            ps2_clk_sync3 <= 1'b1;
            ps2_data_sync1 <= 1'b1;
            ps2_data_sync2 <= 1'b1;
            ps2_data_sync3 <= 1'b1;
        end else begin
            // Synchronize PS/2 clock
            ps2_clk_sync1 <= PS2Clk;
            ps2_clk_sync2 <= ps2_clk_sync1;
            ps2_clk_sync3 <= ps2_clk_sync2;
            
            // Synchronize PS/2 data
            ps2_data_sync1 <= PS2Data;
            ps2_data_sync2 <= ps2_data_sync1;
            ps2_data_sync3 <= ps2_data_sync2;
        end
    end
    
    // Detect falling edge of PS/2 clock
    assign ps2_clk_falling = ps2_clk_sync3 && !ps2_clk_sync2;
    
    //=========================================================================
    // Frame Decoder State Machine
    //=========================================================================
    
    // State register
    always_ff @(posedge clk) begin
        if (reset) begin
            ps2_state <= IDLE;
        end else begin
            ps2_state <= ps2_next_state;
        end
    end
    
    // Next state logic
    always_comb begin
        ps2_next_state = ps2_state;
        
        case (ps2_state)
            IDLE: begin
                // Wait for start bit (falling edge with data = 0)
                if (ps2_clk_falling && !ps2_data_sync3) begin
                    ps2_next_state = START_BIT;
                end
            end
            
            START_BIT: begin
                // Already captured, move to first data bit
                ps2_next_state = DATA_BIT_0;
            end
            
            DATA_BIT_0: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = DATA_BIT_1;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            DATA_BIT_1: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = DATA_BIT_2;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            DATA_BIT_2: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = DATA_BIT_3;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            DATA_BIT_3: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = DATA_BIT_4;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            DATA_BIT_4: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = DATA_BIT_5;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            DATA_BIT_5: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = DATA_BIT_6;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            DATA_BIT_6: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = DATA_BIT_7;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            DATA_BIT_7: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = PARITY_BIT;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            PARITY_BIT: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = STOP_BIT;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            STOP_BIT: begin
                if (ps2_clk_falling) begin
                    ps2_next_state = VALIDATE;
                end else if (timeout_counter == TIMEOUT_CYCLES) begin
                    ps2_next_state = IDLE;
                end
            end
            
            VALIDATE: begin
                // Single cycle validation, then back to IDLE
                ps2_next_state = IDLE;
            end
            
            default: begin
                ps2_next_state = IDLE;
            end
        endcase
    end
    
    // State machine operations
    always_ff @(posedge clk) begin
        if (reset) begin
            shift_reg <= 8'h00;
            parity_bit <= 1'b0;
            stop_bit <= 1'b0;
            timeout_counter <= 14'd0;
            frame_valid <= 1'b0;
            raw_fifo_write <= 1'b0;
        end else begin
            // Default: clear write strobe
            raw_fifo_write <= 1'b0;
            frame_valid <= 1'b0;
            
            case (ps2_state)
                IDLE: begin
                    timeout_counter <= 14'd0;
                    if (ps2_clk_falling && !ps2_data_sync3) begin
                        // Start bit detected, begin frame
                        shift_reg <= 8'h00;
                    end
                end
                
                START_BIT: begin
                    // Start bit already validated in IDLE
                    timeout_counter <= 14'd0;
                end
                
                DATA_BIT_0: begin
                    if (ps2_clk_falling) begin
                        shift_reg[0] <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                DATA_BIT_1: begin
                    if (ps2_clk_falling) begin
                        shift_reg[1] <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                DATA_BIT_2: begin
                    if (ps2_clk_falling) begin
                        shift_reg[2] <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                DATA_BIT_3: begin
                    if (ps2_clk_falling) begin
                        shift_reg[3] <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                DATA_BIT_4: begin
                    if (ps2_clk_falling) begin
                        shift_reg[4] <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                DATA_BIT_5: begin
                    if (ps2_clk_falling) begin
                        shift_reg[5] <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                DATA_BIT_6: begin
                    if (ps2_clk_falling) begin
                        shift_reg[6] <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                DATA_BIT_7: begin
                    if (ps2_clk_falling) begin
                        shift_reg[7] <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                PARITY_BIT: begin
                    if (ps2_clk_falling) begin
                        parity_bit <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                STOP_BIT: begin
                    if (ps2_clk_falling) begin
                        stop_bit <= ps2_data_sync3;
                        timeout_counter <= 14'd0;
                    end else begin
                        timeout_counter <= timeout_counter + 1;
                    end
                end
                
                VALIDATE: begin
                    // Check frame validity
                    // Stop bit must be 1, and odd parity must be correct
                    if (stop_bit && parity_valid) begin
                        frame_valid <= 1'b1;
                        raw_fifo_write <= 1'b1;  // Write to raw FIFO
                    end
                end
                
                default: begin
                    timeout_counter <= 14'd0;
                end
            endcase
        end
    end
    
    // Parity calculation (odd parity)
    // Total number of 1s in data bits + parity bit should be odd
    always_comb begin
        automatic logic [3:0] ones_count;
        ones_count = shift_reg[0] + shift_reg[1] + shift_reg[2] + shift_reg[3] +
                     shift_reg[4] + shift_reg[5] + shift_reg[6] + shift_reg[7] + parity_bit;
        parity_valid = ones_count[0];  // LSB = 1 means odd count
    end
    
    //=========================================================================
    // ASCII Translator Instantiation
    //=========================================================================
    
    ascii_translator ascii_xlate (
        .clk(clk),
        .reset(reset),
        .scan_code(shift_reg),
        .scan_valid(frame_valid),
        .ascii_code(translator_ascii_code),
        .ascii_valid(translator_ascii_valid)
    );
    
    //=========================================================================
    // Raw Scan Code FIFO Management
    //=========================================================================
    
    assign raw_fifo_empty = (raw_fifo_count == 4'd0);
    assign raw_fifo_full = (raw_fifo_count == 4'd8);
    assign raw_fifo_read_data = raw_fifo_mem[raw_fifo_read_ptr];
    
    always_ff @(posedge clk) begin
        if (reset || clear_fifos) begin
            raw_fifo_write_ptr <= 3'd0;
            raw_fifo_read_ptr <= 3'd0;
            raw_fifo_count <= 4'd0;
            raw_fifo_overflow <= 1'b0;
            
            // Clear FIFO memory
            for (int i = 0; i < 8; i++) begin
                raw_fifo_mem[i] <= 8'h00;
            end
        end else begin
            // Handle simultaneous read and write
            if (raw_fifo_write && raw_fifo_read && !raw_fifo_empty) begin
                // Write new data and advance write pointer
                raw_fifo_mem[raw_fifo_write_ptr] <= shift_reg;
                raw_fifo_write_ptr <= raw_fifo_write_ptr + 1;
                // Advance read pointer
                raw_fifo_read_ptr <= raw_fifo_read_ptr + 1;
                // Count stays the same
            end
            // Handle write only
            else if (raw_fifo_write && !raw_fifo_full) begin
                raw_fifo_mem[raw_fifo_write_ptr] <= shift_reg;
                raw_fifo_write_ptr <= raw_fifo_write_ptr + 1;
                raw_fifo_count <= raw_fifo_count + 1;
            end
            // Handle overflow
            else if (raw_fifo_write && raw_fifo_full) begin
                raw_fifo_overflow <= 1'b1;  // Set overflow flag, discard data
            end
            // Handle read only
            else if (raw_fifo_read && !raw_fifo_empty) begin
                raw_fifo_read_ptr <= raw_fifo_read_ptr + 1;
                raw_fifo_count <= raw_fifo_count - 1;
                raw_fifo_overflow <= 1'b0;  // Clear overflow on successful read
            end
        end
    end
    
    //=========================================================================
    // ASCII FIFO Management
    //=========================================================================
    
    assign ascii_fifo_empty = (ascii_fifo_count == 4'd0);
    assign ascii_fifo_full = (ascii_fifo_count == 4'd8);
    assign ascii_fifo_read_data = ascii_fifo_mem[ascii_fifo_read_ptr];
    
    // ASCII FIFO write control - only write valid, non-zero ASCII codes
    assign ascii_fifo_write = translator_ascii_valid && (translator_ascii_code != 7'h00);
    
    always_ff @(posedge clk) begin
        if (reset || clear_fifos) begin
            ascii_fifo_write_ptr <= 3'd0;
            ascii_fifo_read_ptr <= 3'd0;
            ascii_fifo_count <= 4'd0;
            ascii_fifo_overflow <= 1'b0;
            
            // Clear FIFO memory
            for (int i = 0; i < 8; i++) begin
                ascii_fifo_mem[i] <= 8'h00;
            end
        end else begin
            // Handle simultaneous read and write
            if (ascii_fifo_write && ascii_fifo_read && !ascii_fifo_empty) begin
                // Write new data and advance write pointer
                ascii_fifo_mem[ascii_fifo_write_ptr] <= {1'b0, translator_ascii_code};
                ascii_fifo_write_ptr <= ascii_fifo_write_ptr + 1;
                // Advance read pointer
                ascii_fifo_read_ptr <= ascii_fifo_read_ptr + 1;
                // Count stays the same
            end
            // Handle write only
            else if (ascii_fifo_write && !ascii_fifo_full) begin
                ascii_fifo_mem[ascii_fifo_write_ptr] <= {1'b0, translator_ascii_code};
                ascii_fifo_write_ptr <= ascii_fifo_write_ptr + 1;
                ascii_fifo_count <= ascii_fifo_count + 1;
            end
            // Handle overflow
            else if (ascii_fifo_write && ascii_fifo_full) begin
                ascii_fifo_overflow <= 1'b1;  // Set overflow flag, discard data
            end
            // Handle read only
            else if (ascii_fifo_read && !ascii_fifo_empty) begin
                ascii_fifo_read_ptr <= ascii_fifo_read_ptr + 1;
                ascii_fifo_count <= ascii_fifo_count - 1;
                ascii_fifo_overflow <= 1'b0;  // Clear overflow on successful read
            end
        end
    end
    
    //=========================================================================
    // Register Interface
    //=========================================================================
    
    // Generate FIFO read strobes when registers are read
    assign raw_fifo_read = device_select && read_req && 
                          (register_offset == REG_KBD_RAW) && !raw_fifo_empty;
    assign ascii_fifo_read = device_select && read_req && 
                            (register_offset == REG_KBD_ASCII) && !ascii_fifo_empty;
    
    // Control register write handling
    always_ff @(posedge clk) begin
        if (reset) begin
            clear_fifos <= 1'b0;
        end else begin
            clear_fifos <= 1'b0;    // Default: clear strobe
            
            if (device_select && write_req && register_offset == REG_KBD_CONTROL) begin
                clear_fifos <= wdata[0];     // Bit 0 = clear both FIFOs
            end
        end
    end
    
    // Read interface
    always_comb begin
        rdata = 16'hXXXX;  // Default: don't care
        
        if (device_select && read_req) begin
            unique case (register_offset)
                REG_KBD_ASCII: begin
                    // Return ASCII character or 0 if FIFO empty
                    rdata = ascii_fifo_empty ? 16'h0000 : {8'h00, ascii_fifo_read_data};
                end
                REG_KBD_RAW: begin
                    // Return raw scan code or 0 if FIFO empty
                    rdata = raw_fifo_empty ? 16'h0000 : {8'h00, raw_fifo_read_data};
                end
                REG_KBD_STATUS: begin
                    // Status register
                    // [0] = Raw data available
                    // [1] = Raw FIFO full
                    // [2] = Raw FIFO overflow
                    // [3] = ASCII data available
                    // [4] = ASCII FIFO full
                    // [5] = ASCII FIFO overflow
                    // [15:6] = Reserved
                    rdata = {10'h000,                   // [15:6] Reserved
                            ascii_fifo_overflow,         // [5] ASCII overflow
                            ascii_fifo_full,             // [4] ASCII full
                            !ascii_fifo_empty,           // [3] ASCII available
                            raw_fifo_overflow,           // [2] Raw overflow
                            raw_fifo_full,               // [1] Raw full
                            !raw_fifo_empty};            // [0] Raw available
                end
                REG_KBD_CONTROL: begin
                    rdata = 16'h0000;  // Write-only register
                end
                default: begin
                    rdata = 16'hFFFF;  // Unmapped registers
                end
            endcase
        end
    end

endmodule
