module glyph_rom (
    input  logic [6:0]  char_code,    // 7-bit ASCII input (0-127)
    output logic [63:0] glyph_data    // 64-bit glyph bitmap [row7:row6:...:row1:row0]
);

// Function to get glyph data
// Bit ordering for glyph data, starting from LSB: right to left, bottom to top 
function automatic [63:0] get_glyph_data(input [6:0] ascii);
    unique case (ascii)
        // Control characters (0-31) and DEL (127) -> full box
        7'h00, 7'h01, 7'h02, 7'h03, 7'h04, 7'h05, 7'h06, 7'h07,
        7'h08, 7'h09, 7'h0A, 7'h0B, 7'h0C, 7'h0D, 7'h0E, 7'h0F,
        7'h10, 7'h11, 7'h12, 7'h13, 7'h14, 7'h15, 7'h16, 7'h17,
        7'h18, 7'h19, 7'h1A, 7'h1B, 7'h1C, 7'h1D, 7'h1E, 7'h1F,
        7'h7F: return 64'hFFFFFFFFFFFFFFFF;  // Full box
        
        // Printable characters (32-126)
        7'h20: return 64'h0000000000000000;  // Space
        7'h21: return 64'h1818181800180018;  // !
        7'h22: return 64'h6666000000000000;  // "
        7'h23: return 64'h6666FF66FF666600;  // #
        7'h24: return 64'h183E603C067C1800;  // $
        7'h25: return 64'hC6CC18306698C600;  // %
        7'h26: return 64'h386C6C38766EDCCF;  // &
        7'h27: return 64'h1818000000000000;  // '
        7'h28: return 64'h0C18303030180C00;  // (
        7'h29: return 64'h30180C0C0C183000;  // )
        7'h2A: return 64'h0066FF3CFF660000;  // *
        7'h2B: return 64'h0018187E18180000;  // +
        7'h2C: return 64'h0000000018181800;  // ,
        7'h2D: return 64'h0000007E00000000;  // -
        7'h2E: return 64'h0000000000181800;  // .
        7'h2F: return 64'h0306061830606000;  // /
        
        // Numbers 0-9
        7'h30: return 64'h3C66666E76663C00;  // 0
        7'h31: return 64'h1838181818187E00;  // 1
        7'h32: return 64'h3C660C1830607E00;  // 2
        7'h33: return 64'h3C660C1C06663C00;  // 3
        7'h34: return 64'h1C3C6CCC7E0C1E00;  // 4
        7'h35: return 64'h7E607C0606663C00;  // 5
        7'h36: return 64'h1C30607C66663C00;  // 6
        7'h37: return 64'h7E060C1830303000;  // 7
        7'h38: return 64'h3C663C6666663C00;  // 8
        7'h39: return 64'h3C66663E060C3800;  // 9
        
        7'h3A: return 64'h0018180018180000;  // :
        7'h3B: return 64'h0018180018181800;  // ;
        7'h3C: return 64'h0C18306030180C00;  // <
        7'h3D: return 64'h00007E007E000000;  // =
        7'h3E: return 64'h30180C060C183000;  // >
        7'h3F: return 64'h3C660C1818001800;  // ?
        7'h40: return 64'h3C666E6A6E603C00;  // @
        
        // Uppercase Letters A-Z
        7'h41: return 64'h3C66667E66666600;  // A
        7'h42: return 64'h7C667C6666667C00;  // B
        7'h43: return 64'h3C66606060663C00;  // C
        7'h44: return 64'h7C66666666667C00;  // D
        7'h45: return 64'h7E607C6060607E00;  // E
        7'h46: return 64'h7E607C6060606000;  // F
        7'h47: return 64'h3C66606E66663E00;  // G
        7'h48: return 64'h6666667E66666600;  // H
        7'h49: return 64'h7E18181818187E00;  // I
        7'h4A: return 64'h3E0C0C0C0CCC7800;  // J
        7'h4B: return 64'h666C7870786C6600;  // K
        7'h4C: return 64'h6060606060607E00;  // L
        7'h4D: return 64'hC6EEFE6666666600;  // M
        7'h4E: return 64'h6676766E6E666600;  // N
        7'h4F: return 64'h3C66666666663C00;  // O
        7'h50: return 64'h7C66667C60606000;  // P
        7'h51: return 64'h3C666666663C0E00;  // Q
        7'h52: return 64'h7C66667C786C6600;  // R
        7'h53: return 64'h3C66603C06663C00;  // S
        7'h54: return 64'h7E18181818181800;  // T
        7'h55: return 64'h6666666666663C00;  // U
        7'h56: return 64'h6666666666663C00;  // V
        7'h57: return 64'h666666666EFE6600;  // W
        7'h58: return 64'h66663C3C66666600;  // X
        7'h59: return 64'h6666663C18181800;  // Y
        7'h5A: return 64'h7E060C1830607E00;  // Z
        
        7'h5B: return 64'h3C30303030303C00;  // [
        7'h5C: return 64'h6030301818060300;  // \
        7'h5D: return 64'h3C0C0C0C0C0C3C00;  // ]
        7'h5E: return 64'h183C660000000000;  // ^
        7'h5F: return 64'h00000000000000FF;  // _
        7'h60: return 64'h3018000000000000;  // `
        
        // Lowercase Letters a-z
        7'h61: return 64'h00003C063E663E00;  // a
        7'h62: return 64'h60607C6666667C00;  // b
        7'h63: return 64'h00003C6660663C00;  // c
        7'h64: return 64'h06063E6666663E00;  // d
        7'h65: return 64'h00003C667E603C00;  // e
        7'h66: return 64'h1C307C3030303000;  // f
        7'h67: return 64'h00003E66663E067C;  // g
        7'h68: return 64'h60607C6666666600;  // h
        7'h69: return 64'h1800381818183C00;  // i
        7'h6A: return 64'h0C001C0C0C0CCC78;  // j
        7'h6B: return 64'h6060666C786C6600;  // k
        7'h6C: return 64'h3818181818183C00;  // l
        7'h6D: return 64'h0000FED6D6D6D600;  // m
        7'h6E: return 64'h00007C6666666600;  // n
        7'h6F: return 64'h00003C6666663C00;  // o
        7'h70: return 64'h00007C66667C6060;  // p
        7'h71: return 64'h00003E66663E0606;  // q
        7'h72: return 64'h00007C6660606000;  // r
        7'h73: return 64'h00003E603C067C00;  // s
        7'h74: return 64'h00307C3030301C00;  // t
        7'h75: return 64'h00006666666E3E00;  // u
        7'h76: return 64'h0000666666663C00;  // v
        7'h77: return 64'h0000C6D6D6FE6C00;  // w
        7'h78: return 64'h0000663C183C6600;  // x
        7'h79: return 64'h00006666663E067C;  // y
        7'h7A: return 64'h00007E0C18307E00;  // z
        
        7'h7B: return 64'h1C30303060303030;  // {
        7'h7C: return 64'h1818181818181818;  // |
        7'h7D: return 64'h380C0C060C0C0C38;  // }
        7'h7E: return 64'h72DE000000000000;  // ~
    endcase
endfunction

// Glyph lookup
assign glyph_data = get_glyph_data(char_code);

endmodule
