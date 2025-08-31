module uart_controller (
    input  logic        clk,
    input  logic        reset,
    
    // I/O Controller Interface
    input  logic        device_select,     // Device selected by I/O controller
    input  logic [3:0]  register_offset,   // Register within device
    input  logic        read_req,          // Read request
    input  logic        write_req,         // Write request
    input  logic [15:0] wdata,             // Write data
    output logic [15:0] rdata,             // Read data
    
    // UART Interface
    output logic        uart_tx,           // UART TX pin
    input  logic        uart_rx            // UART RX pin
);

    // Register offsets
    localparam logic [3:0] TX_DATA_REG   = 4'h0;  // 0xFFE0: TX Data Word
    localparam logic [3:0] RX_DATA_REG   = 4'h1;  // 0xFFE1: RX Data Word
    localparam logic [3:0] TX_STATUS_REG = 4'h2;  // 0xFFE2: TX Status
    localparam logic [3:0] RX_STATUS_REG = 4'h3;  // 0xFFE3: RX Status
    localparam logic [3:0] TX_BYTE_REG   = 4'h4;  // 0xFFE4: TX Single Byte
    localparam logic [3:0] CONTROL_REG   = 4'h5;  // 0xFFE5: UART Control Register
    
    // Baud rate divisors for 100MHz system clock (pre-decremented for comparison)
    localparam int BAUD_DIV_9600  = 10416;         // (100MHz / 9600) - 1
    localparam int BAUD_DIV_19200 = 5207;          // (100MHz / 19200) - 1
    localparam int BAUD_DIV_38400 = 2603;          // (100MHz / 38400) - 1
    localparam int BAUD_DIV_57600 = 1735;          // (100MHz / 57600) - 1
    
    // Other timing constants
    localparam int TIMEOUT_CYCLES = 31;            // RX timeout in baud cycles  
    localparam int BITS_PER_CHAR = 10;             // Start + 8 data + stop bits
    localparam int BITS_PER_WORD = 20;             // 2 characters per word
    
    // Control register
    logic [15:0] control_reg;
    logic [1:0]  baud_select;
    assign baud_select = control_reg[1:0];
    
    // Variable baud divisor based on control register
    logic [13:0] baud_divisor;
    
    always_comb begin
        unique case (baud_select)
            2'b00: baud_divisor = BAUD_DIV_9600;
            2'b01: baud_divisor = BAUD_DIV_19200;
            2'b10: baud_divisor = BAUD_DIV_38400;
            2'b11: baud_divisor = BAUD_DIV_57600;
        endcase
    end
    
    // BAUD RATE GENERATOR - Single source of timing for all operations
    logic [13:0] baud_counter;
    logic        baud_counter_reset;  // Reset signal when control register changes
    
    // TX FIFO (8 entries deep) with mode tracking per entry
    logic [15:0] tx_fifo [0:7];       // Data storage
    logic        tx_fifo_mode [0:7];  // Mode flags: 0=word mode, 1=byte mode
    logic [2:0]  tx_fifo_head, tx_fifo_tail;
    logic [3:0]  tx_fifo_count;       // Current occupancy: 0-8
    logic        tx_fifo_empty, tx_fifo_full;
    logic        tx_fifo_write, tx_fifo_write_byte, tx_fifo_read;
    logic [15:0] tx_fifo_data_out;    // Current entry data
    logic        tx_fifo_mode_out;    // Current entry mode
    
    // RX FIFO (8 words deep) with parallel padding flags
    logic [15:0] rx_fifo [0:7];      // Data words
    logic        rx_padding_fifo [0:7]; // Padding flags (one per word)
    logic [2:0]  rx_fifo_head, rx_fifo_tail;
    logic [3:0]  rx_fifo_count;  // 0-8 count
    logic        rx_fifo_empty, rx_fifo_full;
    logic        rx_fifo_read;
    logic [15:0] rx_fifo_data_in;
    
    // TX state machine and control signals
    typedef enum logic [2:0] {
        TX_IDLE,           // Waiting for data to transmit
        TX_LOAD_WORD,      // Load FIFO entry into shift register  
        TX_WAIT_BOUNDARY,  // Synchronize to bit boundary
        TX_SEND_CHAR0,     // Transmit first character (or single byte)
        TX_SEND_CHAR1,     // Transmit second character (word mode only)
        TX_COMPLETE_BYTE   // Complete single-byte transmission
    } tx_state_t;
    
    tx_state_t tx_state;
    logic [19:0] tx_shift_reg;         // Shift register: 2 chars max
    logic [4:0]  tx_bit_index;         // Bit position: 0-19
    logic        tx_busy;              // Transmission in progress
    
    // RX state machine and control signals  
    typedef enum logic [2:0] {
        RX_IDLE,           // Waiting for start bit
        RX_START_BIT,      // Sampling start bit for validation
        RX_DATA_BITS,      // Receiving 8 data bits (LSB first)
        RX_STOP_BIT,       // Sampling stop bit 
        RX_ASSEMBLE_WORD   // Waiting for second character or timeout
    } rx_state_t;
    
    rx_state_t rx_state;
    logic [7:0]  rx_shift_reg;         // Current character being received
    logic [2:0]  rx_bit_index;         // Data bit position: 0-7
    logic [4:0]  rx_timeout_count;     // Timeout counter (baud cycles)
    logic [7:0]  rx_char0, rx_char1;   // Assembled word characters
    logic        rx_char0_valid;       // First character received flag
    logic        rx_data_padded;       // Current word requires padding
    
    // FIFO write control - explicit strobes to avoid race conditions
    logic        rx_fifo_write_strobe;   // Explicit FIFO write strobe
    
    // RX input synchronizer (metastability protection) and edge detection
    logic uart_rx_sync1, uart_rx_sync2, uart_rx_sync3;
    logic rx_start_detected;          // Clean falling edge detection (start bit)
    
    // Status registers (combinational)
    logic [15:0] tx_status, rx_status;
    
    // Pre-registered read data to break critical paths
    logic [15:0] rx_data_reg;      // Registered FIFO output
    logic [15:0] tx_status_reg;    // Registered TX status  
    logic [15:0] rx_status_reg;    // Registered RX status
    logic [15:0] control_reg_read; // Registered control register for reads
    
    logic        bit_boundary;        // Pulse at start of each bit period
    logic        sample_point;        // Pulse at middle of each bit period (RX sampling)
    
    // Control register write handling with baud counter reset
    always_ff @(posedge clk) begin
        if (reset) begin
            control_reg <= 16'h0000;  // Default: 9600 baud
            baud_counter_reset <= 1'b0;
        end else begin
            if (device_select && write_req && register_offset == CONTROL_REG) begin
                control_reg <= wdata;
                baud_counter_reset <= 1'b1;  // Reset baud counter on control change
            end else begin
                baud_counter_reset <= 1'b0;
            end
        end
    end
    
    // Baud rate generator with variable divisor
    always_ff @(posedge clk) begin
        if (reset || baud_counter_reset) begin
            baud_counter <= 14'd0;
            bit_boundary <= 1'b0;
            sample_point <= 1'b0;
        end else begin
            if (baud_counter == baud_divisor) begin
                // End of bit period - reset counter and pulse bit_boundary
                baud_counter <= 14'd0;
                bit_boundary <= 1'b1;    // Bit boundary event (start of next bit)
                sample_point <= 1'b0;
            end else begin
                // Count through bit period
                baud_counter <= baud_counter + 1;
                bit_boundary <= 1'b0;
                
                // Sample point at exact middle of bit period (using right-shift)
                if (baud_counter == (baud_divisor >> 1)) begin
                    sample_point <= 1'b1;   // Sample point event (middle of bit)
                end else begin
                    sample_point <= 1'b0;
                end
            end
        end
    end
    
    // RX input synchronizer with edge detection
    always_ff @(posedge clk) begin
        if (reset) begin
            uart_rx_sync1 <= 1'b1;
            uart_rx_sync2 <= 1'b1;
            uart_rx_sync3 <= 1'b1;
            rx_start_detected <= 1'b0;
        end else begin
            // 3-stage synchronizer for metastability protection
            uart_rx_sync1 <= uart_rx;
            uart_rx_sync2 <= uart_rx_sync1;
            uart_rx_sync3 <= uart_rx_sync2;
            
            // Edge detection: falling edge indicates start bit
            rx_start_detected <= uart_rx_sync3 && !uart_rx_sync2;
        end
    end
    
    // TX FIFO management
    assign tx_fifo_empty = (tx_fifo_count == 0);
    assign tx_fifo_full  = (tx_fifo_count == 8);
    assign tx_fifo_data_out = tx_fifo[tx_fifo_tail];
    assign tx_fifo_mode_out = tx_fifo_mode[tx_fifo_tail];
    
    always_ff @(posedge clk) begin
        if (reset) begin
            tx_fifo_head <= 3'd0;
            tx_fifo_tail <= 3'd0;
            tx_fifo_count <= 4'd0;
            // Initialize mode flags
            for (int i = 0; i < 8; i++) begin
                tx_fifo_mode[i] <= 1'b0;
            end
        end else begin
            // Handle simultaneous read and write
            if ((tx_fifo_write || tx_fifo_write_byte) && tx_fifo_read) begin
                // Count stays same, just move pointers
                tx_fifo_head <= tx_fifo_head + 1;
                tx_fifo_tail <= tx_fifo_tail + 1;
                tx_fifo[tx_fifo_head] <= wdata;
                tx_fifo_mode[tx_fifo_head] <= tx_fifo_write_byte;
            end else if ((tx_fifo_write || tx_fifo_write_byte) && !tx_fifo_full) begin
                tx_fifo[tx_fifo_head] <= wdata;
                tx_fifo_mode[tx_fifo_head] <= tx_fifo_write_byte;
                tx_fifo_head <= tx_fifo_head + 1;
                tx_fifo_count <= tx_fifo_count + 1;
            end else if (tx_fifo_read && !tx_fifo_empty) begin
                tx_fifo_tail <= tx_fifo_tail + 1;
                tx_fifo_count <= tx_fifo_count - 1;
            end
        end
    end
    
    // RX FIFO management - with RX-synchronized writes
    assign rx_fifo_empty = (rx_fifo_count == 0);
    assign rx_fifo_full  = (rx_fifo_count == 8);
    
    always_ff @(posedge clk) begin
        if (reset) begin
            rx_fifo_head <= 3'd0;
            rx_fifo_tail <= 3'd0;
            rx_fifo_count <= 4'd0;
            // Initialize padding FIFO
            for (int i = 0; i < 8; i++) begin
                rx_padding_fifo[i] <= 1'b0;
            end
        end else begin
            // RX FIFO operations use explicit strobes
            // Handle simultaneous read and write
            if (rx_fifo_write_strobe && rx_fifo_read) begin
                // Count stays same, just move pointers
                rx_fifo_head <= rx_fifo_head + 1;
                rx_fifo_tail <= rx_fifo_tail + 1;
                // Write both data and padding flag together
                rx_fifo[rx_fifo_head] <= rx_fifo_data_in;
                rx_padding_fifo[rx_fifo_head] <= rx_data_padded;
            end else if (rx_fifo_write_strobe && !rx_fifo_full) begin
                // Write both data and padding flag together
                rx_fifo[rx_fifo_head] <= rx_fifo_data_in;
                rx_padding_fifo[rx_fifo_head] <= rx_data_padded;
                rx_fifo_head <= rx_fifo_head + 1;
                rx_fifo_count <= rx_fifo_count + 1;
            end else if (rx_fifo_read && !rx_fifo_empty) begin
                // CPU read can happen anytime (naturally synchronized by I/O controller)
                // Both data and padding are read together automatically
                rx_fifo_tail <= rx_fifo_tail + 1;
                rx_fifo_count <= rx_fifo_count - 1;
            end
        end
    end
    
    // TX state machine - using unified timing with synchronized start
    always_ff @(posedge clk) begin
        if (reset) begin
            tx_state <= TX_IDLE;
            tx_shift_reg <= 20'd0;
            tx_bit_index <= 5'd0;
            uart_tx <= 1'b1;  // Idle high
            tx_busy <= 1'b0;
        end else begin
            unique case (tx_state)
                TX_IDLE: begin
                    uart_tx <= 1'b1;  // Idle high
                    tx_busy <= 1'b0;
                    if (!tx_fifo_empty) begin
                        tx_state <= TX_LOAD_WORD;
                        tx_busy <= 1'b1;
                    end
                end
                
                TX_LOAD_WORD: begin
                    // Load word from FIFO and prepare shift register
                    if (tx_fifo_mode_out) begin
                        // BYTE MODE: Only prepare first character (char0)
                        // Format: {n.c., n.c., n.c., n.c., n.c., n.c., n.c., n.c., n.c., n.c., 
                        //          stop0, data0[7:0], start0}
                        tx_shift_reg <= {10'b0, 1'b1, tx_fifo_data_out[7:0], 1'b0};
                    end else begin
                        // WORD MODE: Prepare both characters (existing logic)
                        // Format: {stop1, data1[7:0], start1, stop0, data0[7:0], start0}
                        //         {1,     char1,      0,      1,     char0,      0    }
                        tx_shift_reg <= {1'b1, tx_fifo_data_out[15:8], 1'b0, 
                                         1'b1, tx_fifo_data_out[7:0],  1'b0};
                    end
                    tx_bit_index <= 5'd0;
                    tx_state <= TX_WAIT_BOUNDARY;  // Wait for clean bit boundary before starting
                end
                
                TX_WAIT_BOUNDARY: begin
                    // Wait for next bit boundary to ensure first bit has exact timing
                    uart_tx <= 1'b1;  // Keep idle high while waiting
                    if (bit_boundary) begin
                        tx_state <= TX_SEND_CHAR0;
                    end
                end
                
                TX_SEND_CHAR0: begin
                    if (bit_boundary) begin
                        uart_tx <= tx_shift_reg[tx_bit_index];
                        if (tx_bit_index == 9) begin  // Sent all bits of char0
                            if (tx_fifo_mode_out) begin
                                // BYTE MODE: Complete after char0
                                tx_state <= TX_COMPLETE_BYTE;
                            end else begin
                                // WORD MODE: Continue to char1
                                tx_bit_index <= 5'd10;    // Start char1 at bit 10
                                tx_state <= TX_SEND_CHAR1;
                            end
                        end else begin
                            tx_bit_index <= tx_bit_index + 1;
                        end
                    end
                end
                
                TX_SEND_CHAR1: begin
                    if (bit_boundary) begin
                        uart_tx <= tx_shift_reg[tx_bit_index];
                        if (tx_bit_index == 19) begin  // Sent all bits of char1
                            tx_state <= TX_IDLE;
                            tx_busy <= 1'b0;
                        end else begin
                            tx_bit_index <= tx_bit_index + 1;
                        end
                    end
                end
                
                TX_COMPLETE_BYTE: begin
                    // Complete single-byte transmission
                    tx_state <= TX_IDLE;
                    tx_busy <= 1'b0;
                end
                
                default: begin
                    tx_state <= TX_IDLE;
                end
            endcase
        end
    end
    
    // RX state machine
    always_ff @(posedge clk) begin
        if (reset) begin
            rx_state <= RX_IDLE;
            rx_shift_reg <= 8'd0;
            rx_bit_index <= 3'd0;
            rx_timeout_count <= 5'd0;
            rx_char0 <= 8'd0;
            rx_char1 <= 8'd0;
            rx_char0_valid <= 1'b0;
            rx_data_padded <= 1'b0;
            rx_fifo_write_strobe <= 1'b0;
        end else begin
            // Default: clear FIFO write strobe
            rx_fifo_write_strobe <= 1'b0;
            
            unique case (rx_state)
                RX_IDLE: begin
                    rx_char0_valid <= 1'b0;  // Reset for new word
                    rx_timeout_count <= 5'd0;
                    // Wait for start bit detection
                    if (rx_start_detected) begin
                        rx_state <= RX_START_BIT;
                    end
                end
                
                RX_START_BIT: begin
                    // Wait for first sample point (middle of start bit)  
                    if (sample_point) begin
                        if (uart_rx_sync2 == 1'b0) begin  // Confirm start bit is still low
                            rx_state <= RX_DATA_BITS;
                            rx_bit_index <= 3'd0;
                        end else begin
                            rx_state <= RX_IDLE;  // False start, go back to idle
                        end
                    end
                end
                
                RX_DATA_BITS: begin
                    if (sample_point) begin
                        rx_shift_reg[rx_bit_index] <= uart_rx_sync2;  // LSB first
                        if (rx_bit_index == 7) begin
                            rx_state <= RX_STOP_BIT;
                        end else begin
                            rx_bit_index <= rx_bit_index + 1;
                        end
                    end
                end
                
                RX_STOP_BIT: begin
                    if (sample_point) begin
                        // Don't check stop bit validity (ignore errors)
                        if (!rx_char0_valid) begin
                            // FIRST character of word - store and wait for second
                            rx_char0 <= rx_shift_reg;
                            rx_char0_valid <= 1'b1;
                            rx_state <= RX_ASSEMBLE_WORD;
                            rx_timeout_count <= 5'd0;
                        end else begin
                            // SECOND character of word - complete word and write to FIFO
                            rx_char1 <= rx_shift_reg;      // Update data FIRST
                            rx_data_padded <= 1'b0;        // Complete word, no padding
                            rx_char0_valid <= 1'b0;        // Reset immediately after use
                            rx_fifo_write_strobe <= 1'b1;  // Strobe FIFO write AFTER data is stable
                            rx_state <= RX_IDLE;           // Back to idle for next word
                        end
                    end
                end
                
                RX_ASSEMBLE_WORD: begin
                    // Wait for second character or timeout
                    if (rx_start_detected) begin  // Start of second character
                        rx_state <= RX_START_BIT;
                    end else if (sample_point) begin
                        if (rx_timeout_count >= TIMEOUT_CYCLES) begin
                            // TIMEOUT - pad with zero and write to FIFO
                            rx_char1 <= 8'd0;              // Pad with zero FIRST
                            rx_data_padded <= 1'b1;        // Word is padded
                            rx_char0_valid <= 1'b0;        // Reset immediately after use
                            rx_fifo_write_strobe <= 1'b1;  // Strobe FIFO write AFTER data is stable
                            rx_state <= RX_IDLE;           // Back to idle for next word
                        end else begin
                            rx_timeout_count <= rx_timeout_count + 1;
                        end
                    end
                end
                
                default: begin
                    rx_state <= RX_IDLE;
                end
            endcase
        end
    end
    
    // FIFO advancement control - deferred until transmission complete
    logic tx_word_complete, tx_byte_complete;
    assign tx_word_complete = (tx_state == TX_SEND_CHAR1) && (tx_bit_index == 19) && bit_boundary;
    assign tx_byte_complete = (tx_state == TX_COMPLETE_BYTE);
    assign tx_fifo_read = tx_word_complete || tx_byte_complete;
    
    // RX FIFO data input - always reflects current assembled word
    assign rx_fifo_data_in = {rx_char1, rx_char0};  // Little endian
    
    // Register access control signals
    assign tx_fifo_write      = (device_select && write_req && register_offset == TX_DATA_REG);
    assign tx_fifo_write_byte = (device_select && write_req && register_offset == TX_BYTE_REG);
    assign rx_fifo_read       = (device_select && read_req  && register_offset == RX_DATA_REG);
    
    // Status register generation (combinational)
    always_comb begin
        // TX Status: [3]=Full, [2]=Empty, [1]=Busy, [0]=Unused
        tx_status = 16'd0;
        tx_status[3] = tx_fifo_full;   // TX FIFO Full
        tx_status[2] = tx_fifo_empty;  // TX FIFO Empty
        tx_status[1] = tx_busy;        // TX Busy
        
        // RX Status: [3]=Full, [2]=Empty, [1]=Available, [0]=Padded  
        rx_status = 16'd0;
        rx_status[3] = rx_fifo_full;   // RX FIFO Full
        rx_status[2] = rx_fifo_empty;  // RX FIFO Empty  
        rx_status[1] = !rx_fifo_empty; // RX Data Available
        rx_status[0] = !rx_fifo_empty && rx_padding_fifo[rx_fifo_tail]; // RX Data Padded
    end
    
    // Register critical timing components every cycle
    always_ff @(posedge clk) begin
        // Register FIFO read immediately after distributed RAM to break critical path
        rx_data_reg <= rx_fifo_empty ? 16'h0000 : rx_fifo[rx_fifo_tail];
        
        // Register status signals every cycle for consistent timing
        tx_status_reg <= tx_status;
        rx_status_reg <= rx_status;
        
        // Register control register for reads
        control_reg_read <= control_reg;
    end
    
    // Fast combinational read multiplexer using pre-registered values
    always_comb begin
        rdata = 16'hXXXX;  // Default: don't care
        if (device_select && read_req) begin
            unique case (register_offset)
                TX_DATA_REG:   rdata = 16'hFFFF;         // Write-only register
                TX_BYTE_REG:   rdata = 16'hFFFF;         // Write-only register  
                RX_DATA_REG:   rdata = rx_data_reg;      // Pre-registered FIFO data
                TX_STATUS_REG: rdata = tx_status_reg;    // Pre-registered status
                RX_STATUS_REG: rdata = rx_status_reg;    // Pre-registered status
                CONTROL_REG:   rdata = control_reg_read; // Pre-registered control
                default:       rdata = 16'hFFFF;         // Unmapped registers (bus pull-ups)
            endcase
        end
    end

endmodule
