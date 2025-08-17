module dmem #(
    parameter ADDR_WIDTH = 15,        // 15-bit addressing (32K words)
    parameter INIT_FILE = "dmem.mem"          // Optional initialization file
) (
    input  logic                    clk,
    input  logic                    clk_en,      // Clock enable for speed control
    input  logic [ADDR_WIDTH-1:0]   raddr,       // Read address
    input  logic [ADDR_WIDTH-1:0]   waddr,       // Write address  
    input  logic [15:0]             wdata,       // Write data
    input  logic                    we,          // Write enable
    output logic [15:0]             rdata        // Read data (1-cycle latency)
);

    localparam DEPTH = 2**ADDR_WIDTH;  // Memory depth in words
    
    // Block RAM storage
    (* ram_style = "block" *) logic [15:0] memory [0:DEPTH-1];
    
    // Initialize memory from file if specified
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, memory);
        end
    end
    
    // Synchronous read and write with clock enable
    always_ff @(posedge clk) begin
        if (clk_en) begin
            // Write operation
            if (we) begin
                memory[waddr] <= wdata;
            end
            
            // Read operation (1-cycle latency)
            rdata <= memory[raddr];
        end
    end

endmodule
