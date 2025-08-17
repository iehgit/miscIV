module misc_core #(
    parameter IMEMW = 14              // Instruction memory address width (14-bit = 16K words)
) (
    input  logic        clk,
    input  logic        clk_en,          // Clock enable for speed control
    input  logic        reset,
    
    // Interrupt Interface
    input  logic        irq_request,     // Interrupt request input (high priority)
    input  logic        irq2_request,    // Interrupt request input (low priority)
    output logic        irq_busy,        // Interrupt system busy - external hardware should wait
    
    // IMEM interface (external)
    output logic [IMEMW-1:0]   imem_addr,            // Next address to IMEM
    output logic               imem_branch_override, // Branch override signal
    output logic [IMEMW-1:0]   imem_branch_target,   // Branch target address
    input  logic [15:0]        imem_data,            // Instruction from IMEM
    input  logic [IMEMW-1:0]   imem_data_addr,       // Address from IMEM
    
    // DMEM interface (external)
    output logic [14:0]         dmem_raddr,          // Read address to DMEM
    output logic [14:0]         dmem_waddr,          // Write address to DMEM
    output logic [15:0]         dmem_wdata,          // Write data to DMEM
    output logic                dmem_we,             // Write enable to DMEM
    input  logic [15:0]         dmem_rdata,          // Read data from DMEM
    
    // I/O Controller Interface (Stage 2->3 pipeline)
    output logic [15:0] io_addr,         // I/O address to controller
    output logic [15:0] io_wdata,        // I/O write data to controller  
    output logic        io_read_req,     // I/O read request to controller
    output logic        io_write_req,    // I/O write request to controller
    input  logic [15:0] io_rdata,        // I/O read data from controller
    
    // Debug outputs
    output logic [15:0] pc_display,
    output logic        dp0,         // Debug: instruction is NOPed
    output logic        dp1,         // Debug: ISR is busy
    output logic        dp2,         // Debug: available for future use
    output logic        dp3          // Debug: available for future use
);

    // Interrupt vector addresses (32 words reserved for each ISR at end of memory)
    localparam logic [IMEMW-1:0] INTERRUPT_VECTOR  = 14'h3FE0; // for IRQ1 (high priority)
    localparam logic [IMEMW-1:0] INTERRUPT_VECTOR2 = 14'h3FC0; // for IRQ2 (low priority)

    logic [IMEMW-1:0] next_imem_addr;       // Next (i.e. not current) imem address
    logic [IMEMW-1:0] next_next_imem_addr;  // next_imem_addr + 1
    logic [15:0] imem_instr;                // Instruction fetched from imem
    logic [IMEMW-1:0] imem_instr_addr;      // Address from IMEM
    logic [IMEMW-1:0] exec_pc;              // PC in decode/execute stage
    
    // Decoded instruction signals
    logic [3:0] opcode, rd, rs1, rs2, imm4;
    logic [7:0] imm8;
    logic is_load, is_store;
    
    // Branch control signals
    logic branch_detected_ex;          // Branch detected in Stage 2
    logic branch_detected_wb;          // Branch detected signal pipelined to Stage 3
    
    // Stage 2 bubble control: delayed branch signal creates 2-cycle NOP sequence
    logic branch_detected_ex_delayed;  // Extends NOP sequence for 1 additional cycle
    logic branch_detected_ex_delayed2; // Third cycle delay for proper safe state tracking
    
    logic [IMEMW-1:0] branch_target;   // Branch target address
    logic branch_override;             // Override imem addressing
    logic r15_flag_bit;                // R15 flag bit storage (preserved from last R15 write)
    
    // R13 auto-decrement signals
    logic r13_used_as_source;          // R13 used as rs1 or rs2 in Stage 2
    logic r13_decrement_req_reg;       // Pipelined R13 decrement request to Stage 3
    
    // R14 LIFO stack signals and storage
    logic r14_used_as_source;          // R14 used as source in Stage 2
    logic r14_used_as_dest;            // R14 used as destination in Stage 2
    logic r14_push_req_reg;            // Pipelined R14 push request to Stage 3
    logic r14_pop_req_reg;             // Pipelined R14 pop request to Stage 3
    logic [16:0] r14_write_data;       // Data to write to R14 stack (for push/modify operations)
    logic [7:0] r14_main_stack [0:15]; // Main stack: [top, 2nd, 3rd, ..., 8th] - 16-bit data only
    logic [7:0] r14_shadow_stack [0:15]; // Shadow stack: [2nd, 3rd, 4th, ..., 8th, X] - 16-bit data only  
    logic [15:0] r14_next_top_16;      // Next stack top after pop (16-bit data)
    
    // Address and data signals for LOAD/STORE operations
    logic [15:0] mem_addr;                 // Memory address calculation (rs1 + rs2)
    logic [15:0] mem_addr_reg;             // Pipelined memory address  
    logic        is_load_reg;              // Pipelined LOAD instruction flag
    logic [15:0] store_data;               // Store data (from rd register)
    logic        store_to_dmem, store_to_io; // Store address decoding
    
    // Register read data signals
    logic [16:0] rs1_data, rs2_data, rd_data;
    
    // ALU output signals
    logic [16:0] result;
    logic        condition_met;
    
    // Base register write enable (before R15 exclusion)
    logic base_reg_we;
    
    // Register Write Enable (excludes R15)
    logic reg_we;
    
    // Stage 2->3 pipeline registers
    logic [16:0] result_reg;          // Latched ALU result
    logic [3:0]  rd_reg;              // Latched destination register
    logic        reg_we_reg;          // Latched write enable
    logic        load_from_dmem;      // DMEM load control
    logic        load_from_io;        // I/O load control
    
    // Register file (R0-R14, R15 completely intercepted but flag preserved)
    logic [16:0] reg_file [0:14];     // R0-R14 (R15 reads/writes intercepted, flag stored separately)
    
    // Shadow register file for ISR context (R0-R7 only)
    logic [16:0] shadow_reg_file [0:7]; // Shadow storage for ISR context switching
    
    logic [15:0] loaded_data;         // Data to load from memory/IO (DMEM/I/O)
    
    // Register Read with Forwarding (handles LOAD-use hazards)
    logic [16:0] forwarded_data;      // Forwarded data for register reads
    
    // Debug signals
    logic        instruction_noped_reg; // Registered version to match actual NOP timing
    
    // Interrupt control signals
    logic        irq_sync1, irq_sync2;   // IRQ input synchronizer
    logic        irq_edge_detected;      // Rising edge detection
    logic        irq_request_latched;    // Latched interrupt request (full speed latch)
    logic        irq2_sync1, irq2_sync2; // IRQ2 input synchronizer
    logic        irq2_edge_detected;     // IRQ2 rising edge detection
    logic        irq2_request_latched;   // IRQ2 latched interrupt request
    logic        active_irq_is_irq2;     // Track which interrupt is being serviced
    logic [1:0]  reset_delay_counter;    // Reset delay counter
    logic        irq_enabled;            // IRQ enabled after reset delay
    logic        safe_state;             // Pipeline in safe state for ISR entry
    
    // Interrupt state machine
    typedef enum logic [1:0] {
        IRQ_IDLE,           // No interrupt processing
        IRQ_PENDING,        // IRQ detected, waiting for safe state
        IRQ_ENTERING,       // ISR entry in progress (branch issued)
        IRQ_ACTIVE          // ISR executing
    } irq_state_t;
    
    irq_state_t irq_state;
    
    // Interrupt control outputs
    logic [IMEMW-1:0] isr_return_addr;       // Return address storage
    logic        isr_exit_detected;          // ISR exit condition detected (Stage 3)
    logic        isr_exit_delayed;           // Track first NOP cycle of ISR exit
    logic        interrupt_entry_delayed;    // Track first NOP cycle of interrupt entry
    logic        interrupt_entry_delayed2;   // Track second NOP cycle of interrupt entry
    logic        interrupt_branch_wb;        // Track when interrupt branch reaches Stage 3
    
    // Branch detection signals
    logic        normal_branch_detected;     // Normal branch detected signal
    logic        interrupt_branch_detected;  // Interrupt branch detected signal
    
    // Forwarding control signals
    logic        forwarding_disabled;        // Disable forwarding during ISR context operations
    
    // Connect internal signals to external IMEM interface
    assign imem_addr = next_imem_addr;
    assign imem_branch_override = branch_override;
    assign imem_branch_target = branch_target;
    assign imem_instr = imem_data;
    assign imem_instr_addr = imem_data_addr;
    
    // Connect internal signals to external DMEM interface
    assign dmem_raddr = mem_addr[14:0];
    assign dmem_waddr = mem_addr[14:0];
    assign dmem_wdata = store_data;
    assign dmem_we = store_to_dmem;
    
    
    // 3 Stage Pipeline =====================================================
    // Stage 1: Instruction Memory Address Control
    //   - PC advancement logic (next_imem_addr)
    //   - Branch override (when branch_override asserted)
    //   - Address redirection for branches (branch_target)
    //   - imem BRAM addressing
    //
    // Stage 2: Fetch, Decode, Execute  
    //   - Instruction fetch and decode
    //   - ALU execution and control signal generation
    //   - Branch detection (writes to R15)
    //   - NOP bubble logic (2-cycle branch delay handling)
    //   - R15 special handling (reads return exec_pc+flag, writes trigger branches)
    //   - R13 auto-decrement detection (rs1 or rs2 == 13)
    //   - R14 LIFO stack operation detection (push/pop/modify operations)
    //   - Load/store address calculation (rs1 + rs2)
    //   - I/O controller interface (address, data, control signals)
    //   - Forwarding logic for LOAD-use hazards
    //   - ISR exit detection (R15 write of 0x0000 during ISR)
    //
    // Stage 3: Writeback and Branch Resolution
    //   - Register writeback (ALU results and LOAD data) including R14
    //   - R13 auto-decrement execution
    //   - R14 LIFO stack operations (push/pop/modify)
    //   - LOAD data selection (DMEM/I/O) 
    //   - Branch target calculation (from ALU result or loaded data)
    //   - Branch override signal generation
    //   - R15 flag capture from branch operations
    //   - DMEM handling (I/O moved to separate controller)
    //   - ISR context restore operations
    // ======================================================================
    
    
    // Interrupt Request Synchronization and Edge Detection (always at full speed)
    always_ff @(posedge clk) begin
        if (reset) begin
            irq_sync1 <= 1'b0;
            irq_sync2 <= 1'b0;
            irq_edge_detected <= 1'b0;
            irq2_sync1 <= 1'b0;
            irq2_sync2 <= 1'b0;
            irq2_edge_detected <= 1'b0;
        end else begin
            // 2-stage synchronizer for metastability protection (IRQ1)
            irq_sync1 <= irq_request;
            irq_sync2 <= irq_sync1;
            irq_edge_detected <= irq_sync1 && !irq_sync2;
            
            // 2-stage synchronizer for metastability protection (IRQ2)
            irq2_sync1 <= irq2_request;
            irq2_sync2 <= irq2_sync1;
            irq2_edge_detected <= irq2_sync1 && !irq2_sync2;
        end
    end
    
    // IRQ Enable with 3-cycle delay
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (reset) begin
                reset_delay_counter <= 2'd0;
                irq_enabled <= 1'b0;
            end else if (!irq_enabled) begin
                if (reset_delay_counter == 2'b11) begin
                    irq_enabled <= 1'b1;
                end else begin
                    reset_delay_counter <= reset_delay_counter + 1;
                end
            end
        end
    end
    
    // IRQ Request Latching (always at full speed to catch edges)
    always_ff @(posedge clk) begin
        if (reset) begin
            irq_request_latched <= 1'b0;
            irq2_request_latched <= 1'b0;
            active_irq_is_irq2 <= 1'b0;
        end else begin
            // Handle IRQ request latching with priority (IRQ1 wins ties)
            if (irq_edge_detected && irq_enabled) begin
                irq_request_latched <= 1'b1;
                // IRQ1 has priority - don't latch IRQ2 this cycle
            end else if (irq2_edge_detected && irq_enabled && !irq_request_latched) begin
                irq2_request_latched <= 1'b1;
            end else if (interrupt_branch_detected && clk_en) begin
                // Clear appropriate latch when ISR entry begins (only when CPU active)
                // Set tracking for branch target selection
                active_irq_is_irq2 <= irq2_request_latched;
                if (irq_request_latched) begin
                    irq_request_latched <= 1'b0;
                end else begin
                    irq2_request_latched <= 1'b0;
                end
            end
        end
    end
    
    // Hybrid Safe State Detection
    // Combinational: detect normal branch starting THIS cycle
    // Safe state: no normal branch starting now AND no branch activity for 3-cycle sequence
    assign safe_state = !normal_branch_detected && 
                       !(branch_detected_ex_delayed ||     // Cycle N+1: first NOP
                         branch_detected_ex_delayed2 ||    // Cycle N+2: second NOP  
                         branch_override);                 // Any cycle: branch override active
    
    // IRQ Entry Logic
    assign interrupt_branch_detected = irq_enabled && safe_state && (irq_state == IRQ_PENDING) && 
                                      (irq_request_latched || irq2_request_latched);
    
    // ISR Exit Detection - trap R15 write of 0x0000 during ISR (Stage 3)
    assign isr_exit_detected = branch_detected_wb && (result_reg[15:0] == 16'h0000) && (irq_state == IRQ_ACTIVE);
    
    // IRQ State Machine
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (reset) begin
                irq_state <= IRQ_IDLE;
            end else begin
                unique case (irq_state)
                    IRQ_IDLE: begin
                        // New IRQ detected - move to pending
                        if (irq_request_latched || irq2_request_latched) begin
                            irq_state <= IRQ_PENDING;
                        end
                    end
                    
                    IRQ_PENDING: begin
                        // Wait for safe state, then trigger entry
                        if (interrupt_branch_detected) begin
                            irq_state <= IRQ_ENTERING;
                        end
                    end
                    
                    IRQ_ENTERING: begin
                        // ISR entry branch has been issued, wait for it to complete
                        // When the interrupt branch reaches Stage 3, we're fully in the ISR
                        if (interrupt_branch_wb) begin
                            irq_state <= IRQ_ACTIVE;
                        end
                    end
                    
                    IRQ_ACTIVE: begin
                        // Exit when ISR writes 0x0000 to R15
                        if (isr_exit_detected) begin
                            irq_state <= IRQ_IDLE;
                        end
                    end
                    
                    default: irq_state <= IRQ_IDLE;
                endcase
            end
        end
    end
    
    // IRQ System Busy Signal Generation
    assign irq_busy = (irq_state != IRQ_IDLE) || irq_request_latched || irq2_request_latched;
    
    // Shadow Register Operations and Context Switching + Return Address Capture
    always_ff @(posedge clk) begin
        if (clk_en) begin
            // ISR Entry: Context save during FIRST NOP cycle - save FINAL state including pending writeback
            if (interrupt_entry_delayed) begin
                for (int i = 0; i < 8; i++) begin
                    if (reg_we_reg && rd_reg == i) begin
                        // Save the value being written by the "Last Normal" instruction
                        shadow_reg_file[i] <= is_load_reg ? {1'b0, loaded_data} : result_reg;
                    end else begin
                        // Save current register value (no pending writeback to this register)
                        shadow_reg_file[i] <= reg_file[i];
                    end
                end
            end
        end
    end
    
    // ISR Return Address Capture - during first NOP cycle when exec_pc points to NOPed instruction
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (irq_state == IRQ_ENTERING && interrupt_entry_delayed) begin
                // Capture during first NOP cycle: exec_pc now points to the NOPed instruction
                isr_return_addr <= exec_pc;  // "First instruction you skipped"
            end
        end
    end

    // R14 next stack top extraction (for pop forwarding)
    always_comb begin
        for (int i = 0; i < 16; i++) begin
            r14_next_top_16[i] = r14_shadow_stack[i][0];
        end
    end

    // R14 write data calculation (combinational)
    assign r14_write_data = is_load_reg ? {1'b0, loaded_data} : result_reg;
    
    // Compute next address increment for normal operation
    assign next_next_imem_addr = next_imem_addr + 1;
    
    // Branch override uses existing mechanism only
    assign branch_override = branch_detected_wb;
    
    // Branch target selection with ISR handling
    always_comb begin
        if (isr_exit_detected) begin
            branch_target = isr_return_addr;    // ISR return address (substitute for 0x0000)
        end else if (irq_state == IRQ_ENTERING && interrupt_branch_wb) begin
            branch_target = active_irq_is_irq2 ? INTERRUPT_VECTOR2 : INTERRUPT_VECTOR;   // Interrupt vector
        end else if (branch_detected_wb) begin
            if (is_load_reg) begin
                branch_target = loaded_data[IMEMW-1:0];  // LOAD branch: use loaded data
            end else begin
                branch_target = result_reg[IMEMW-1:0];   // ALU branch: use ALU result
            end
        end else begin
            branch_target = 'x;  // Don't care - should not be used
        end
    end
    
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (reset) begin
                next_imem_addr <= 0;
            end else if (branch_override) begin
                // +2 accounts for 3-cycle address pipeline: when branch_override ends,
                // imem needs next_raddr that's 2 ahead of branch_target to maintain flow
                next_imem_addr <= branch_target + 2;
            end else begin
                next_imem_addr <= next_next_imem_addr;  // Normal increment
            end
        end
    end
    
    assign pc_display = {{16-IMEMW{1'b0}}, exec_pc};  // Show currently executing PC
    
    // Debug outputs
    assign dp0 = instruction_noped_reg;   // Show when instruction is NOPed (synchronized)
    assign dp1 = irq_busy;                // Show interrupt system busy status
    assign dp2 = 1'b0;                    // Available for future debug signal
    assign dp3 = 1'b0;                    // Available for future debug signal
    
    // Debug logic
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (reset) begin
                instruction_noped_reg <= 1'b0;
            end else begin
                // Register the NOP condition to match actual NOP timing
                instruction_noped_reg <= branch_detected_ex || branch_detected_ex_delayed;
            end
        end
    end
    
    // Branch Detection (Stage 2) - unified for normal branches and interrupts  
    assign normal_branch_detected = (rd == 4'd15) && ~is_store && condition_met;
    assign branch_detected_ex = normal_branch_detected || interrupt_branch_detected;
    
    // Base register write enable (before R15 exclusion)
    assign base_reg_we = ~is_store && condition_met;
    
    // R13 Auto-Decrement Detection (Stage 2)
    // Decrement when R13 is read as rs1, rs2, or rd (for STORE)
    assign r13_used_as_source = ((opcode != 4'h8 && opcode != 4'h9) && (rs1 == 4'd13)) ||  // rs1 source (except ALI/SUI)
                                ((opcode[3] == 1'b0 || opcode == 4'hB || opcode == 4'hC || opcode == 4'hD) && (rs2 == 4'd13)) || // rs2 source
                                ((opcode == 4'hD) && (rd == 4'd13));  // rd source for STORE
    
    // R14 LIFO Stack Detection (Stage 2)
    // Use same logic as R13 for source detection, plus destination detection
    assign r14_used_as_source = ((opcode != 4'h8 && opcode != 4'h9) && (rs1 == 4'd14)) ||  // rs1 source (except ALI/SUI)
                                ((opcode[3] == 1'b0 || opcode == 4'hB || opcode == 4'hC || opcode == 4'hD) && (rs2 == 4'd14)) || // rs2 source
                                ((opcode == 4'hD) && (rd == 4'd14));  // rd source for STORE
    
    assign r14_used_as_dest = (rd == 4'd14) && base_reg_we;  // R14 as destination
    
    // Branch delayed signals (3-cycle delay chain for safe state tracking)
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (reset) begin
                // Stage 2 delayed signals
                branch_detected_ex_delayed <= 1'b0;
                branch_detected_ex_delayed2 <= 1'b0;
                interrupt_entry_delayed <= 1'b0;
                interrupt_entry_delayed2 <= 1'b0;
                isr_exit_delayed <= 1'b0;
            end else begin
                // Stage 2: 3-cycle delay chain for unsafe sequence tracking
                branch_detected_ex_delayed <= branch_detected_ex;
                branch_detected_ex_delayed2 <= branch_detected_ex_delayed;
                interrupt_entry_delayed <= interrupt_branch_detected;
                interrupt_entry_delayed2 <= interrupt_entry_delayed;  // Second delay for register clearing
                isr_exit_delayed <= isr_exit_detected;  // Delay ISR exit for first NOP cycle timing
            end
        end
    end
    
    // Latch decoded instruction (with bubble support)
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (reset) begin
                opcode   <= 4'h0;
                rd       <= 4'h0;
                rs1      <= 4'h0;
                rs2      <= 4'h0;
                imm4     <= 4'h0;
                imm8     <= 8'h00;
                is_load  <= 1'b0;
                is_store <= 1'b0;
                exec_pc  <= {IMEMW{1'b0}};
            end else begin
                // exec_pc always advances normally - never freeze it
                exec_pc <= imem_instr_addr;
                
                // NOP timing: unified branch mechanism handles both normal branches and interrupts
                // Creates exactly 2 cycles of NOPs starting immediately when branch detected:
                // Cycle N:   branch_detected_ex=1, _delayed=0 -> (1||0)=1 -> NOP
                // Cycle N+1: branch_detected_ex=0, _delayed=1 -> (0||1)=1 -> NOP  
                // Cycle N+2: branch_detected_ex=0, _delayed=0 -> (0||0)=0 -> Execute
                if (branch_detected_ex || branch_detected_ex_delayed) begin
                    // NOP instruction fields during 2-cycle bubble sequence after branch detection
                    opcode   <= 4'h0;  // NOP-like operation
                    rd       <= 4'h0;
                    rs1      <= 4'h0;
                    rs2      <= 4'h0;
                    imm4     <= 4'h0;
                    imm8     <= 8'h00;
                    is_load  <= 1'b0;
                    is_store <= 1'b0;
                end else begin
                    // Normal instruction decode
                    opcode   <= imem_instr[15:12];
                    rd       <= imem_instr[11: 8];
                    rs1      <= imem_instr[ 7: 4];
                    rs2      <= imem_instr[ 3: 0];
                    imm4     <= imem_instr[ 3: 0];
                    imm8     <= imem_instr[ 7: 0];
                    is_load  <= imem_instr[15:12] == 4'hC;
                    is_store <= imem_instr[15:12] == 4'hD;
                end
            end
        end
    end
    
    // Register Read with Forwarding and R15 Special Handling
    // Hazards handled: LOAD-use for all registers, R14 pop forwarding
    // Hazards not handled: R13 simultaneous read+write forwarding (accepts stale data for timing)
    
    assign forwarded_data = is_load_reg ? {1'b0, loaded_data} : result_reg;
    assign forwarding_disabled = isr_exit_delayed;  // Disable forwarding during context restore
    
    assign rs1_data = (rs1 == 4'd15) ? {r15_flag_bit, {17-1-IMEMW{1'b0}}, exec_pc} : // R15 read returns flag + current PC
                      (rs1 == 4'd14 && r14_pop_req_reg && !r14_push_req_reg) ? {reg_file[14][16], r14_next_top_16} : // R14 pop: forward post-pop top
                      (!forwarding_disabled && rs1 == rd_reg && reg_we_reg) ? forwarded_data : reg_file[rs1];
    assign rs2_data = (rs2 == 4'd15) ? {r15_flag_bit, {17-1-IMEMW{1'b0}}, exec_pc} : // R15 read returns flag + current PC
                      (rs2 == 4'd14 && r14_pop_req_reg && !r14_push_req_reg) ? {reg_file[14][16], r14_next_top_16} : // R14 pop: forward post-pop top
                      (!forwarding_disabled && rs2 == rd_reg && reg_we_reg) ? forwarded_data : reg_file[rs2];
    assign rd_data  = (rd == 4'd15) ? {r15_flag_bit, {17-1-IMEMW{1'b0}}, exec_pc} : // R15 read returns flag + current PC
                      (rd == 4'd14 && r14_pop_req_reg && !r14_push_req_reg) ? {reg_file[14][16], r14_next_top_16} :  // R14 pop: forward post-pop top
                      (!forwarding_disabled && rd == rd_reg && reg_we_reg) ? forwarded_data : reg_file[rd];
    
    // Register Write Enable (don't write to R15 - R14 handled in stack operations)
    assign reg_we = base_reg_we && (rd != 4'd15);
    
    // Stage 2->3 pipeline registers (no bubbles needed for this pipeline stage)
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (reset) begin
                result_reg <= 17'b0;
                rd_reg <= 4'h0;
                reg_we_reg <= 1'b0;
                mem_addr_reg <= 16'h0;
                is_load_reg <= 1'b0;
                branch_detected_wb <= 1'b0;
                r13_decrement_req_reg <= 1'b0;
                r14_push_req_reg <= 1'b0;
                r14_pop_req_reg <= 1'b0;
                interrupt_branch_wb <= 1'b0;
            end else begin
                // Update pipeline - NOPed instructions from Stage 2 are harmless
                result_reg <= result;            // Latch ALU result directly
                rd_reg <= rd;                    // Latch destination
                reg_we_reg <= reg_we;            // Latch write enable
                mem_addr_reg <= mem_addr;        // Latch memory address
                is_load_reg <= is_load;          // Latch LOAD instruction flag
                branch_detected_wb <= branch_detected_ex; // Pipeline branch signal
                r13_decrement_req_reg <= r13_used_as_source && condition_met; // Only decrement if condition met
                r14_push_req_reg <= r14_used_as_dest;     // Push/modify whenever writing to R14
                r14_pop_req_reg <= r14_used_as_source;    // Pop/modify whenever reading from R14
                interrupt_branch_wb <= interrupt_branch_detected; // Pipeline interrupt branch signal
            end
        end
    end
    
    // Register Writeback with R13 Auto-Decrement and R14 LIFO Stack (Stage 3)
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (reset) begin
                // Regular register file reset (R0-R14)
                for (int i = 0; i < 15; i++) begin
                    if (i == 12) begin
                        reg_file[i] <= 17'h00001;  // R12 initialized to 1
                    end else begin
                        reg_file[i] <= 17'b0;      // All other registers to 0
                    end
                end
                
                // R15 flag bit reset
                r15_flag_bit <= 1'b0;
                
                // R14 stack reset
                for (int i = 0; i < 16; i++) begin
                    r14_main_stack[i] <= 8'b0;
                    r14_shadow_stack[i] <= 8'b0;
                end
            end else begin
                // ISR context operations use unified NOP cycle timing  
                if (interrupt_entry_delayed2) begin
                    // ISR Entry: Clear R0-R7 during SECOND NOP cycle
                    for (int i = 0; i < 8; i++) begin
                        reg_file[i] <= 17'h00000;
                    end
                end else if (isr_exit_delayed) begin
                    // ISR Exit: Restore R0-R7 during FIRST NOP cycle
                    for (int i = 0; i < 8; i++) begin
                        reg_file[i] <= shadow_reg_file[i];
                    end
                end
                // Normal register writeback (R0-R13) - R14/R15 writes intercepted for special handling
                else if (reg_we_reg && rd_reg != 4'd14) begin
                    if (rd_reg == 4'd13 && r13_decrement_req_reg) begin
                        // R13 used as both source and destination: writeback result minus 1
                        if (is_load_reg) begin
                            reg_file[rd_reg] <= {1'b0, loaded_data} - 17'd1;
                        end else begin
                            reg_file[rd_reg] <= result_reg - 17'd1;
                        end
                    end else begin
                        // Normal writeback (excluding R14)
                        if (is_load_reg) begin
                            reg_file[rd_reg] <= {1'b0, loaded_data};  // LOAD: use memory/IO data
                        end else begin
                            reg_file[rd_reg] <= result_reg;           // ALU: use ALU result
                        end
                    end
                end
                
                // R15 flag bit capture (when R15 is written to for branching)
                if (branch_detected_wb && !isr_exit_detected) begin
                    if (is_load_reg) begin
                        r15_flag_bit <= 1'b0;               // LOAD branch: no flag (address load)
                    end else begin
                        r15_flag_bit <= result_reg[16];     // ALU branch: capture ALU overflow flag
                    end
                end
                
                // R13 auto-decrement for source-only case (independent of normal writeback)
                if (r13_decrement_req_reg && !(reg_we_reg && rd_reg == 4'd13)) begin
                    reg_file[4'd13] <= reg_file[4'd13] - 17'd1;
                end
                
                // R14 LIFO stack operations (maintain main and shadow stacks, update reg_file[14])
                if (r14_push_req_reg || r14_pop_req_reg) begin
                    if (r14_push_req_reg && !r14_pop_req_reg) begin
                        // Push: shift left and insert new data, update reg_file[14]
                        reg_file[14] <= r14_write_data;
                        
                        // Update stacks
                        for (int i = 0; i < 16; i++) begin
                            r14_main_stack[i] <= {r14_main_stack[i][6:0], r14_write_data[i]};        // Shift main
                            r14_shadow_stack[i] <= {r14_shadow_stack[i][6:0], r14_main_stack[i][0]}; // Old top -> shadow
                        end
                    end else if (r14_pop_req_reg && !r14_push_req_reg) begin
                        // Pop: shift right, update reg_file[14] with new top, preserve flag
                        // Update reg_file[14] with new stack top (keep flag from before pop)
                        reg_file[14] <= {reg_file[14][16], r14_next_top_16};
                        
                        // Update stacks
                        for (int i = 0; i < 16; i++) begin
                            r14_main_stack[i] <= {1'b0, r14_main_stack[i][7:1]};     // Shift main right
                            r14_shadow_stack[i] <= {1'b0, r14_shadow_stack[i][7:1]}; // Shift shadow right
                        end
                    end else begin
                        // Modify top: both push and pop true, update reg_file[14]
                        reg_file[14] <= r14_write_data;
                        
                        // Update stack top only
                        for (int i = 0; i < 16; i++) begin
                            r14_main_stack[i][0] <= r14_write_data[i];  // Change main top only
                            // Shadow unchanged (second entry stays same)
                        end
                    end
                end
            end
        end
    end
    
    // LOAD/STORE Operation Logic ==========================================

    // Calculate memory address (rs1 + rs2) - used for both loads and stores
    assign mem_addr = rs1_data[15:0] + rs2_data[15:0];
    
    // Store data comes from rd register (not ALU result)
    assign store_data = rd_data[15:0];
    
    // Address decoding (Stage 2): I/O vs DMEM based on MSB
    assign store_to_dmem = is_store && (mem_addr[15] == 1'b0);  // MSB=0: DMEM
    assign store_to_io   = is_store && (mem_addr[15] == 1'b1);  // MSB=1: I/O
    
    // Stage 3 address decoding (using pipelined address)
    assign load_from_dmem = is_load_reg && (mem_addr_reg[15] == 1'b0);  // MSB=0: DMEM
    assign load_from_io   = is_load_reg && (mem_addr_reg[15] == 1'b1);  // MSB=1: I/O
    
    // I/O Controller Interface (Stage 2)
    assign io_addr      = mem_addr;                           // Send address to I/O controller
    assign io_wdata     = store_data;                         // Send write data to I/O controller
    assign io_read_req  = is_load && (mem_addr[15] == 1'b1);  // I/O read request
    assign io_write_req = store_to_io;                        // I/O write request
    
    // Load data selection (Stage 3: using pipelined signals)
    always_comb begin
        if (load_from_dmem) begin
            loaded_data = dmem_rdata;    // Read from DMEM BRAM
        end else if (load_from_io) begin
            loaded_data = io_rdata;      // Read from I/O controller
        end else begin
            loaded_data = 16'hXXXX;      // No load operation (don't care)
        end
    end
    
    // ALU (combinational logic)
    alu alu (
        .opcode(opcode),
        .rs1_data(rs1_data),
        .rs2_data(rs2_data),
        .rd_data(rd_data),
        .imm8(imm8),
        .imm4(imm4),
        .result(result),
        .condition_met(condition_met)
    );

endmodule
