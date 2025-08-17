# 16-BIT MISC PROCESSOR ARCHITECTURE REFERENCE

## ARCHITECTURE FUNDAMENTALS
This is a 16-bit MISC (Minimal Instruction Set Computer) with Harvard architecture 
featuring separate instruction and data memories, word-addressed organization, 
memory-mapped I/O, and a 3-stage pipeline with specialized register behaviors.

## INSTRUCTION SET (16 OPCODES)

| HEX | MNEMONIC | FULL NAME                    | FORMAT                |
|-----|----------|------------------------------|-----------------------|
| 0x0 | AND      | Bitwise AND                  | AND   rd, rs1, rs2    |
| 0x1 | NAND     | Bitwise NAND                 | NAND  rd, rs1, rs2    |
| 0x2 | OR       | Bitwise OR                   | OR    rd, rs1, rs2    |
| 0x3 | XOR      | Bitwise XOR                  | XOR   rd, rs1, rs2    |
| 0x4 | ADD      | Addition                     | ADD   rd, rs1, rs2    |
| 0x5 | SUB      | Subtraction                  | SUB   rd, rs1, rs2    |
| 0x6 | SHR      | Shift Right                  | SHR   rd, rs1, rs2    |
| 0x7 | SHL      | Shift Left                   | SHL   rd, rs1, rs2    |
| 0x8 | ALI      | Add Lower Immediate          | ALI   rd, imm8        |
| 0x9 | SUI      | Set Upper Immediate          | SUI   rd, imm8        |
| 0xA | ADDI     | Add Immediate                | ADDI  rd, rs1, imm4   |
| 0xB | BITW     | Bit Width                    | BITW  rd, rs1, rs2    |
| 0xC | LOAD     | Load from Memory             | LOAD  rd, [rs1+rs2]   |
| 0xD | STORE    | Store to Memory              | STORE rd, [rs1+rs2]   |
| 0xE | CAIZ     | Conditional Add If Zero      | CAIZ  rd, rs1, imm4   |
| 0xF | CAIF     | Conditional Add If Flag      | CAIF  rd, rs1, imm4   |

**NOTES:**
- SHR performs logical shift if flag=0, arithmetic shift if flag=1
- BITW returns position (1-16) of highest set bit in (rs1 & rs2), or 0 if none

### INSTRUCTION FORMAT
- `[15:12]` = opcode (4 bits)
- `[11:8]`  = rd (destination register, 4 bits)  
- `[7:4]`   = rs1 (source register 1, 4 bits)  
- `[3:0]`   = rs2 (source register 2, 4 bits) OR imm4 (4-bit immediate)
- `[7:0]`   = imm8 (8-bit immediate for ALI/SUI)

### PSEUDO-OPERATIONS
- `NOP`  = 0x0000 = AND R0, R0, R0 (no operation)
- `IRET` = 0x9F00 = SUI R15, 0x00 (ISR exit)

## REGISTER FILE (16 REGISTERS)

| REG | QUIRKS AND SPECIAL BEHAVIORS                                     | ISR SHADOW |
|-----|------------------------------------------------------------------|------------|
| R0  | General purpose register                                         | YES        |
| R1  | General purpose register                                         | YES        |
| R2  | General purpose register                                         | YES        |
| R3  | General purpose register                                         | YES        |
| R4  | General purpose register                                         | YES        |
| R5  | General purpose register                                         | YES        |
| R6  | General purpose register                                         | YES        |
| R7  | General purpose register                                         | YES        |
| R8  | General purpose register                                         | NO         |
| R9  | General purpose register                                         | NO         |
| R10 | General purpose register                                         | NO         |
| R11 | General purpose register                                         | NO         |
| R12 | Initialized to 1 on reset (others initialize to 0)             | NO         |
| R13 | Auto-decrements when used as source operand                     | NO         |
| R14 | LIFO stack: push on write, pop on read, 8-level deep           | NO         |
| R15 | Program counter: reads return current PC+flag, writes trigger branches | NO   |

**NOTES:**
- All registers R0-R15 are 17 bits wide (16 data + 1 flag bit)
- R15 reads return {flag_bit, current_PC} but triggers branches when written
- Branches are performed by writing target address to R15
- R13 auto-decrement occurs for ANY source usage (rs1, rs2, or STORE rd)
- R14 stack operations: write=push, read=pop, simultaneous=modify top
- Flag bits capture overflow from arithmetic operations and control shift behavior

## INTERRUPT SYSTEM

**INPUTS:** Two interrupt request lines with different priorities and vectors
- IRQ1 (high priority) wins simultaneous requests at 0x3FE0
- IRQ2 (low priority) serviced only if IRQ1 idle at 0x3FC0

**CONTEXT:** R0-R7 have shadow registers for automatic save/restore during ISR

## MEMORY-MAPPED I/O DEVICES

All I/O devices are accessed via memory-mapped registers at addresses 0x8000-0xFFFF.

### SIMPLE I/O (0xFFF0-0xFFFF)

| ADDRESS | NAME            | R/W | DESCRIPTION                         |
|---------|-----------------|-----|-------------------------------------|
| 0xFFFC  | CYCLE_CTR       | R/W | Free-running cycle counter         |
| 0xFFFD  | SECONDS_CTR     | R/W | Seconds counter (~1Hz)             |
| 0xFFFE  | SWITCHES        | R   | 16 slide switches                  |
| 0xFFFF  | LEDS            | R/W | 16 LED outputs                     |

### UART (0xFFE0-0xFFEF)

| ADDRESS | NAME            | R/W | DESCRIPTION                         |
|---------|-----------------|-----|-------------------------------------|
| 0xFFE0  | TX_DATA         | W   | Transmit 16-bit word (2 chars)     |
| 0xFFE1  | RX_DATA         | R   | Receive 16-bit word (2 chars)      |
| 0xFFE2  | TX_STATUS       | R   | [3]=Full, [2]=Empty, [1]=Busy      |
| 0xFFE3  | RX_STATUS       | R   | [3]=Full, [2]=Empty, [1]=Avail, [0]=Padded |
| 0xFFE4  | TX_BYTE         | W   | Transmit single byte                |

**NOTES:** 9600 baud, 8N1. 4-entry FIFOs for TX and RX. Word mode sends/receives 2 characters. RX pads single chars with 0x00 after timeout.

### GPU (0xFFD0-0xFFDF)

| ADDRESS | NAME            | R/W | DESCRIPTION                         |
|---------|-----------------|-----|-------------------------------------|
| 0xFFD0  | CHAR_INPUT      | R/W | [15:8]=ASCII2+inv, [7:0]=ASCII1+inv |
| 0xFFD1  | CHAR_COORD      | R/W | [12:8]=Y (0-24), [5:0]=X (0-39)    |
| 0xFFD2  | CHAR_CONTROL    | W   | [11]=Clear, [10]=Add, [9]=FixPos, [8]=PutChar |
| 0xFFD5  | PIXEL_DATA      | R/W | 16 pixels bitmap data              |
| 0xFFD6  | GRAPHICS_COORD  | R/W | [15:8]=Y (0-199), [5:0]=X (0-39)   |
| 0xFFD7  | GRAPHICS_CTRL   | W   | [11]=Clear, [10]=Add, [9]=FixPos, [8]=PutPixel |
| 0xFFD9  | STATUS          | R   | [0]=Busy                            |
| 0xFFDA  | PALETTE_1       | R/W | Palette bits [15:0] for cell rows 0-15 |
| 0xFFDB  | PALETTE_2       | R/W | Palette bits [24:16] for cell rows 16-24 |
| 0xFFDC  | FLIP_CONTROL    | R/W | [9]=Display buffer, [8]=Write buffer |
| 0xFFDD  | COLOR_VALUES    | R/W | [15:8]=FG[7:4]/BG[3:0] for color cell |
| 0xFFDE  | COLOR_COORD     | R/W | [12:8]=Y (0-24), [5:0]=X (0-39)    |
| 0xFFDF  | COLOR_CONTROL   | W   | [11]=Clear colors, [8]=PutColor    |

**NOTES:** 
- 320x200 monochrome pixels, double-buffered, 640x400@70Hz VGA output
- 40x25 color cells (8x8 pixels each)
- Each cell has 4-bit foreground + 4-bit background color
- Palette mode per cell row: 0=16-color VGA, 1=16-level grayscale
- Text mode: 40x25 chars, 8x8 ROM font, supports control codes

### ROM (0xFFC0-0xFFCF)

| ADDRESS | NAME            | R/W | DESCRIPTION                         |
|---------|-----------------|-----|-------------------------------------|
| 0xFFC0  | ROM_ADDR        | W   | Word address (write triggers read) |
| 0xFFC1  | ROM_DATA        | R   | Read data (16-bit word)            |
| 0xFFC2  | ROM_STATUS      | R   | [0]=Data valid                     |

**NOTES:** 64K words (128KB) stored in SPI flash at 2MB offset. Quad-SPI interface at 50MHz. Write to ROM_ADDR triggers read, poll ROM_STATUS[0] for completion (~880ns).

### AUDIO (0xFFB0-0xFFBF)

| ADDRESS | NAME            | R/W | DESCRIPTION                         |
|---------|-----------------|-----|-------------------------------------|
| 0xFFB0  | SAW_FREQ        | R/W | Sawtooth frequency in Hz           |
| 0xFFB1  | SAW_DURATION    | R/W | Sawtooth duration in ms (triggers) |
| 0xFFB2  | SQUARE_FREQ     | R/W | Square wave frequency in Hz        |
| 0xFFB3  | SQUARE_DURATION | R/W | Square duration in ms (triggers)   |

**NOTES:** I2S audio output at 48kHz sample rate, 16-bit resolution. Writing duration triggers playback.

## RESET

System reset is controlled by the right button (BTNR).

**OPERATION:**
- Press BTNR to reset CPU, registers, and memory controllers
- Speed setting and Altair mode persist through reset
- All registers initialize to 0 except R12 (initializes to 1)

## SPEED CONTROL

The processor supports two execution speeds controlled by the center button (BTNC).

### MODES
- **100MHz:** Normal full-speed operation (default)
- **1Hz:** Slow-speed operation for debugging (~1 instruction/second)

### OPERATION
- **Toggle:** Press BTNC to switch between speeds
- **Persistence:** Speed setting survives CPU reset (BTNR)

**NOTE:** Speed control only affects CPU and memory. I/O devices maintain full speed for proper operation.

## ALTAIR MODE

Front-panel programming mode for manual memory inspection and modification.

### CONTROLS
- **Enter:** Short press BTNL (left button)
- **Exit:** Long press BTNL
- **Memory Select:** Short press BTNL toggles IMEM/DMEM
- **Examine:** BTNU loads address from switches, reads memory
- **Deposit:** BTND writes switches data to current address, auto-increments

### INDICATORS
- **LEDs:** Display 16-bit data at current address
- **7-Segment:** See DISPLAY INDICATORS section

**NOTE:** CPU halts during Altair mode. Address auto-increments after deposits.

## DISPLAY INDICATORS

The 7-segment display provides real-time system status.

**NORMAL MODE:**
- **Display:** Current PC (program counter) value
- **DP1:** ISR active indicator
- **DP0:** Instruction NOPed (branch bubble)

**ALTAIR MODE:**
- **Display:** Current memory address
- **DP3:** IMEM selected
- **DP2:** DMEM/IO selected