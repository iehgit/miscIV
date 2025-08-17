module imem #(
    parameter ADDR_WIDTH = 14,        // Default: 16384 words
    parameter INIT_FILE = "imem.mem"  // Default initialization file
) (
    input  logic                    clk,
    input  logic                    clk_en,             // Clock enable for speed control
    input  logic [ADDR_WIDTH-1:0]   next_raddr,         // Next read address (normal operation)
    input  logic                    branch_override,    // Branch override signal
    input  logic [ADDR_WIDTH-1:0]   branch_target_addr, // Branch target address
    output logic [15:0]             data_out,           // Instruction
    output logic [ADDR_WIDTH-1:0]   addr_out,           // Instructions address
    
    // Altair mode write port
    input  logic                    altair_we,          // Write enable for Altair mode
    input  logic [ADDR_WIDTH-1:0]   altair_waddr,       // Write address for Altair mode
    input  logic [15:0]             altair_wdata        // Write data for Altair mode
);

    localparam DEPTH = 2**ADDR_WIDTH;  // Memory depth in words
    
    // Block RAM storage
    (* ram_style = "block" *) logic [15:0] memory [0:DEPTH-1];
    
    // Initialize memory from file
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, memory);
        end
    end
    
    logic [ADDR_WIDTH-1:0] raddr;  // Current read address
    
    // Synchronous read with immediate branch override and clock enable
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (branch_override) begin
                data_out <= memory[branch_target_addr];  // Immediate override
                addr_out <= branch_target_addr;          // Immediate override
            end else begin
                data_out <= memory[raddr];
                addr_out <= raddr;
            end
        end
    end
    
    // Address selection (normal increment and override for next cycle) with clock enable
    always_ff @(posedge clk) begin
        if (clk_en) begin
            if (branch_override) begin
                raddr <= branch_target_addr + 1;  // Setup for instruction after branch target
            end else begin
                raddr <= next_raddr;              // Normal sequential addressing
            end
        end
    end
    
    // Altair mode write port (independent of clock enable)
    always_ff @(posedge clk) begin
        if (altair_we) begin
            memory[altair_waddr] <= altair_wdata;
        end
    end

endmodule
