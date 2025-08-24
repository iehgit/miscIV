module ascii_lookup_rom (
    input  logic [7:0] scan_code,       // PS/2 Set 2 scan code
    output logic [6:0] ascii_normal,    // Unshifted ASCII
    output logic [6:0] ascii_shifted    // Shifted ASCII
);

    // Combinational lookup table
    // PS/2 Set 2 scan codes to ASCII mapping
    always_comb begin        
        unique case (scan_code)
            //==================================================================
            // Special Keys (same for normal and shifted)
            //==================================================================
            8'h29: begin  // Space
                ascii_normal = 7'h20;   // ' '
                ascii_shifted = 7'h20;  // ' '
            end
            
            8'h5A: begin  // Enter
                ascii_normal = 7'h0A;   // LF (Line Feed)
                ascii_shifted = 7'h0A;  // LF
            end
            
            8'h66: begin  // Backspace
                ascii_normal = 7'h08;   // BS
                ascii_shifted = 7'h08;  // BS
            end
            
            8'h0D: begin  // Tab
                ascii_normal = 7'h09;   // HT (Horizontal Tab)
                ascii_shifted = 7'h09;  // HT
            end
            
            8'h76: begin  // Escape
                ascii_normal = 7'h1B;   // ESC
                ascii_shifted = 7'h1B;  // ESC
            end
            
            //==================================================================
            // Numbers (Top Row)
            //==================================================================
            8'h16: begin  // 1
                ascii_normal = 7'h31;   // '1'
                ascii_shifted = 7'h21;  // '!'
            end
            
            8'h1E: begin  // 2
                ascii_normal = 7'h32;   // '2'
                ascii_shifted = 7'h40;  // '@'
            end
            
            8'h26: begin  // 3
                ascii_normal = 7'h33;   // '3'
                ascii_shifted = 7'h23;  // '#'
            end
            
            8'h25: begin  // 4
                ascii_normal = 7'h34;   // '4'
                ascii_shifted = 7'h24;  // '$'
            end
            
            8'h2E: begin  // 5
                ascii_normal = 7'h35;   // '5'
                ascii_shifted = 7'h25;  // '%'
            end
            
            8'h36: begin  // 6
                ascii_normal = 7'h36;   // '6'
                ascii_shifted = 7'h5E;  // '^'
            end
            
            8'h3D: begin  // 7
                ascii_normal = 7'h37;   // '7'
                ascii_shifted = 7'h26;  // '&'
            end
            
            8'h3E: begin  // 8
                ascii_normal = 7'h38;   // '8'
                ascii_shifted = 7'h2A;  // '*'
            end
            
            8'h46: begin  // 9
                ascii_normal = 7'h39;   // '9'
                ascii_shifted = 7'h28;  // '('
            end
            
            8'h45: begin  // 0
                ascii_normal = 7'h30;   // '0'
                ascii_shifted = 7'h29;  // ')'
            end
            
            //==================================================================
            // Letters (A-Z)
            //==================================================================
            8'h1C: begin  // A
                ascii_normal = 7'h61;   // 'a'
                ascii_shifted = 7'h41;  // 'A'
            end
            
            8'h32: begin  // B
                ascii_normal = 7'h62;   // 'b'
                ascii_shifted = 7'h42;  // 'B'
            end
            
            8'h21: begin  // C
                ascii_normal = 7'h63;   // 'c'
                ascii_shifted = 7'h43;  // 'C'
            end
            
            8'h23: begin  // D
                ascii_normal = 7'h64;   // 'd'
                ascii_shifted = 7'h44;  // 'D'
            end
            
            8'h24: begin  // E
                ascii_normal = 7'h65;   // 'e'
                ascii_shifted = 7'h45;  // 'E'
            end
            
            8'h2B: begin  // F
                ascii_normal = 7'h66;   // 'f'
                ascii_shifted = 7'h46;  // 'F'
            end
            
            8'h34: begin  // G
                ascii_normal = 7'h67;   // 'g'
                ascii_shifted = 7'h47;  // 'G'
            end
            
            8'h33: begin  // H
                ascii_normal = 7'h68;   // 'h'
                ascii_shifted = 7'h48;  // 'H'
            end
            
            8'h43: begin  // I
                ascii_normal = 7'h69;   // 'i'
                ascii_shifted = 7'h49;  // 'I'
            end
            
            8'h3B: begin  // J
                ascii_normal = 7'h6A;   // 'j'
                ascii_shifted = 7'h4A;  // 'J'
            end
            
            8'h42: begin  // K
                ascii_normal = 7'h6B;   // 'k'
                ascii_shifted = 7'h4B;  // 'K'
            end
            
            8'h4B: begin  // L
                ascii_normal = 7'h6C;   // 'l'
                ascii_shifted = 7'h4C;  // 'L'
            end
            
            8'h3A: begin  // M
                ascii_normal = 7'h6D;   // 'm'
                ascii_shifted = 7'h4D;  // 'M'
            end
            
            8'h31: begin  // N
                ascii_normal = 7'h6E;   // 'n'
                ascii_shifted = 7'h4E;  // 'N'
            end
            
            8'h44: begin  // O
                ascii_normal = 7'h6F;   // 'o'
                ascii_shifted = 7'h4F;  // 'O'
            end
            
            8'h4D: begin  // P
                ascii_normal = 7'h70;   // 'p'
                ascii_shifted = 7'h50;  // 'P'
            end
            
            8'h15: begin  // Q
                ascii_normal = 7'h71;   // 'q'
                ascii_shifted = 7'h51;  // 'Q'
            end
            
            8'h2D: begin  // R
                ascii_normal = 7'h72;   // 'r'
                ascii_shifted = 7'h52;  // 'R'
            end
            
            8'h1B: begin  // S
                ascii_normal = 7'h73;   // 's'
                ascii_shifted = 7'h53;  // 'S'
            end
            
            8'h2C: begin  // T
                ascii_normal = 7'h74;   // 't'
                ascii_shifted = 7'h54;  // 'T'
            end
            
            8'h3C: begin  // U
                ascii_normal = 7'h75;   // 'u'
                ascii_shifted = 7'h55;  // 'U'
            end
            
            8'h2A: begin  // V
                ascii_normal = 7'h76;   // 'v'
                ascii_shifted = 7'h56;  // 'V'
            end
            
            8'h1D: begin  // W
                ascii_normal = 7'h77;   // 'w'
                ascii_shifted = 7'h57;  // 'W'
            end
            
            8'h22: begin  // X
                ascii_normal = 7'h78;   // 'x'
                ascii_shifted = 7'h58;  // 'X'
            end
            
            8'h35: begin  // Y
                ascii_normal = 7'h79;   // 'y'
                ascii_shifted = 7'h59;  // 'Y'
            end
            
            8'h1A: begin  // Z
                ascii_normal = 7'h7A;   // 'z'
                ascii_shifted = 7'h5A;  // 'Z'
            end
            
            //==================================================================
            // Punctuation and Symbols
            //==================================================================
            8'h0E: begin  // ` (grave accent / tilde)
                ascii_normal = 7'h60;   // '`'
                ascii_shifted = 7'h7E;  // '~'
            end
            
            8'h4E: begin  // - (minus / underscore)
                ascii_normal = 7'h2D;   // '-'
                ascii_shifted = 7'h5F;  // '_'
            end
            
            8'h55: begin  // = (equals / plus)
                ascii_normal = 7'h3D;   // '='
                ascii_shifted = 7'h2B;  // '+'
            end
            
            8'h54: begin  // [ (left bracket / left brace)
                ascii_normal = 7'h5B;   // '['
                ascii_shifted = 7'h7B;  // '{'
            end
            
            8'h5B: begin  // ] (right bracket / right brace)
                ascii_normal = 7'h5D;   // ']'
                ascii_shifted = 7'h7D;  // '}'
            end
            
            8'h5D: begin  // \ (backslash / pipe)
                ascii_normal = 7'h5C;   // '\'
                ascii_shifted = 7'h7C;  // '|'
            end
            
            8'h4C: begin  // ; (semicolon / colon)
                ascii_normal = 7'h3B;   // ';'
                ascii_shifted = 7'h3A;  // ':'
            end
            
            8'h52: begin  // ' (apostrophe / quote)
                ascii_normal = 7'h27;   // '''
                ascii_shifted = 7'h22;  // '"'
            end
            
            8'h41: begin  // , (comma / less than)
                ascii_normal = 7'h2C;   // ','
                ascii_shifted = 7'h3C;  // '<'
            end
            
            8'h49: begin  // . (period / greater than)
                ascii_normal = 7'h2E;   // '.'
                ascii_shifted = 7'h3E;  // '>'
            end
            
            8'h4A: begin  // / (slash / question)
                ascii_normal = 7'h2F;   // '/'
                ascii_shifted = 7'h3F;  // '?'
            end
            
            //==================================================================
            // All unmapped keys return 0x00 (no ASCII representation)
            //==================================================================
            default: begin
                ascii_normal = 7'h00;
                ascii_shifted = 7'h00;
            end
        endcase
    end

endmodule
