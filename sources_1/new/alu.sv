module alu (
    input  logic [3:0]  opcode,
    input  logic [16:0] rs1_data,      // Source register 1 data (16-bit + flag)
    input  logic [16:0] rs2_data,      // Source register 2 data (16-bit + flag)
    input  logic [16:0] rd_data,       // Destination register data (16-bit + flag)
    input  logic [7:0]  imm8,          // 8-bit immediate
    input  logic [3:0]  imm4,          // 4-bit immediate
    output logic [16:0] result,        // Result (16-bit + flag)
    output logic        condition_met  // Condition met for CAIZ/CAIF
);

    // Combinational ALU logic
    always_comb begin
        // Default: condition is met (for non-conditional operations)
        condition_met = 1'b1;
    
        unique case (opcode)
            4'h0: result = rs1_data & rs2_data;        // AND (17-bit)
            4'h1: result = ~(rs1_data & rs2_data);     // NAND (17-bit)
            4'h2: result = rs1_data | rs2_data;        // OR (17-bit)
            4'h3: result = rs1_data ^ rs2_data;        // XOR (17-bit)
            4'h4: result = {1'b0, rs1_data[15:0]} + {1'b0, rs2_data[15:0]}; // ADD
            4'h5: result = {1'b0, rs1_data[15:0]} - {1'b0, rs2_data[15:0]}; // SUB
            
            4'h6: result = rs1_data[16:0] >>> rs2_data[3:0];  // SHR - Shift Right (flag=0: logical, flag=1: arithmetic, preserves flag)
            4'h7: result = rs1_data[16:0] << rs2_data[3:0];   // SHL - Shift Left (17-bit operation, preserves and shifts flag)
            
            4'h8: result = {1'b0, rd_data[15:0]} + {9'b0, imm8};         // ALI - Add Lower Immediate
            4'h9: result = {1'b0, imm8, 8'b0};                           // SUI - Set Upper Immediate
            4'hA: result = {1'b0, rs1_data[15:0]} + {13'b0, imm4};       // ADDI - Add Immediate
            
            4'hB: begin  // BITW - Bit Width
                automatic logic [15:0] temp_val;
                automatic logic [4:0] temp_result;
                
                temp_val = rs1_data[15:0] & rs2_data[15:0];
                
                unique casez (temp_val)
                    16'b1???_????_????_????: temp_result = 5'd16;
                    16'b01??_????_????_????: temp_result = 5'd15;
                    16'b001?_????_????_????: temp_result = 5'd14;
                    16'b0001_????_????_????: temp_result = 5'd13;
                    16'b0000_1???_????_????: temp_result = 5'd12;
                    16'b0000_01??_????_????: temp_result = 5'd11;
                    16'b0000_001?_????_????: temp_result = 5'd10;
                    16'b0000_0001_????_????: temp_result = 5'd9;
                    16'b0000_0000_1???_????: temp_result = 5'd8;
                    16'b0000_0000_01??_????: temp_result = 5'd7;
                    16'b0000_0000_001?_????: temp_result = 5'd6;
                    16'b0000_0000_0001_????: temp_result = 5'd5;
                    16'b0000_0000_0000_1???: temp_result = 5'd4;
                    16'b0000_0000_0000_01??: temp_result = 5'd3;
                    16'b0000_0000_0000_001?: temp_result = 5'd2;
                    16'b0000_0000_0000_0001: temp_result = 5'd1;
                    16'b0000_0000_0000_0000: temp_result = 5'd0; 
                endcase
                
                result = {1'b0, 11'b0, temp_result};
            end
            
            4'hE: begin  // CAIZ - Conditional Add If Zero
                if (rs1_data[15:0] == 16'b0)
                    result = {1'b0, rd_data[15:0]} + {13'b0, imm4};
                else begin
                    condition_met = 1'b0;
                    result = rd_data;
                end
            end
            
            4'hF: begin  // CAIF - Conditional Add If Flag
                if (rs1_data[16])
                    result = {1'b0, rd_data[15:0]} + {13'b0, imm4};
                else begin
                    condition_met = 1'b0;
                    result = rd_data;
                end
            end
            
            default: result = 17'bx;  // Don't care - not used by LOAD/STORE
        endcase
    end

endmodule
