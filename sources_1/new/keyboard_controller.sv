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

    // Register offsets
    localparam logic [3:0] REG_KBD_ASCII   = 4'h0;  // ASCII character (unimplemented)
    localparam logic [3:0] REG_KBD_RAW     = 4'h1;  // Raw scan code
    localparam logic [3:0] REG_KBD_STATUS  = 4'h2;  // Status register
    localparam logic [3:0] REG_KBD_CONTROL = 4'h3;  // Control register
    
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
    
    // FIFO for scan codes (8-deep)
    logic [7:0]  fifo_mem [0:7];      // FIFO memory
    logic [2:0]  fifo_write_ptr;      // Write pointer
    logic [2:0]  fifo_read_ptr;       // Read pointer
    logic [3:0]  fifo_count;          // Number of entries (0-8)
    logic        fifo_write;          // Write strobe
    logic        fifo_read;           // Read strobe
    logic        fifo_empty;          // FIFO empty flag
    logic        fifo_full;           // FIFO full flag
    logic        fifo_overflow;       // Overflow occurred
    logic [7:0]  fifo_read_data;      // Data at read pointer
    
    // Control signals
    logic        clear_fifo;          // Clear FIFO command
    
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
            fifo_write <= 1'b0;
        end else begin
            // Default: clear write strobe
            fifo_write <= 1'b0;
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
                        fifo_write <= 1'b1;  // Write to FIFO
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
    // FIFO Management
    //=========================================================================
    
    assign fifo_empty = (fifo_count == 4'd0);
    assign fifo_full = (fifo_count == 4'd8);
    assign fifo_read_data = fifo_mem[fifo_read_ptr];
    
    always_ff @(posedge clk) begin
        if (reset || clear_fifo) begin
            fifo_write_ptr <= 3'd0;
            fifo_read_ptr <= 3'd0;
            fifo_count <= 4'd0;
            fifo_overflow <= 1'b0;
            
            // Clear FIFO memory
            for (int i = 0; i < 8; i++) begin
                fifo_mem[i] <= 8'h00;
            end
        end else begin
            // Handle simultaneous read and write
            if (fifo_write && fifo_read && !fifo_empty) begin
                // Write new data and advance write pointer
                fifo_mem[fifo_write_ptr] <= shift_reg;
                fifo_write_ptr <= fifo_write_ptr + 1;
                // Advance read pointer
                fifo_read_ptr <= fifo_read_ptr + 1;
                // Count stays the same
            end
            // Handle write only
            else if (fifo_write && !fifo_full) begin
                fifo_mem[fifo_write_ptr] <= shift_reg;
                fifo_write_ptr <= fifo_write_ptr + 1;
                fifo_count <= fifo_count + 1;
            end
            // Handle overflow
            else if (fifo_write && fifo_full) begin
                fifo_overflow <= 1'b1;  // Set overflow flag, discard data
            end
            // Handle read only
            else if (fifo_read && !fifo_empty) begin
                fifo_read_ptr <= fifo_read_ptr + 1;
                fifo_count <= fifo_count - 1;
                fifo_overflow <= 1'b0;  // Clear overflow on successful read
            end
        end
    end
    
    //=========================================================================
    // Register Interface
    //=========================================================================
    
    // Generate FIFO read strobe when RAW register is read
    assign fifo_read = device_select && read_req && (register_offset == REG_KBD_RAW) && !fifo_empty;
    
    // Control register write handling
    always_ff @(posedge clk) begin
        if (reset) begin
            clear_fifo <= 1'b0;
        end else begin
            clear_fifo <= 1'b0;  // Default: clear strobe
            
            if (device_select && write_req && register_offset == REG_KBD_CONTROL) begin
                clear_fifo <= wdata[0];  // Bit 0 = clear FIFO
            end
        end
    end
    
    // Read interface
    always_comb begin
        rdata = 16'hXXXX;  // Default: don't care
        
        if (device_select && read_req) begin
            unique case (register_offset)
                REG_KBD_ASCII: begin
                    rdata = 16'h0000;  // ASCII not implemented yet
                end
                REG_KBD_RAW: begin
                    rdata = fifo_empty ? 16'h0000 : {8'h00, fifo_read_data};
                end
                REG_KBD_STATUS: begin
                    // [2]=Overflow, [1]=Full, [0]=Data available
                    rdata = {13'h0000, fifo_overflow, fifo_full, !fifo_empty};
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
