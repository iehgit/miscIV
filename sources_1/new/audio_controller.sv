module audio_controller (
    input  logic        clk,           // 100MHz system clock
    input  logic        reset,         // System reset (100MHz domain only)
    
    // I/O Controller Interface (100MHz domain)
    input  logic        device_select,
    input  logic [3:0]  register_offset,
    input  logic        read_req,
    input  logic        write_req,
    input  logic [15:0] wdata,
    output logic [15:0] rdata,
    
    // I2S Interface to Pmod (24.576MHz domain)
    output logic        audio_mclk,    // Master clock to Pmod
    output logic        audio_lrck,    // L/R word select
    output logic        audio_sclk,    // Serial bit clock
    output logic        audio_sdin     // Serial data out to DAC
);

    // Power-On Self Test: Plays a 3000Hz sawtooth tone for 500ms at reset
    // This provides immediate audio feedback that the system is working

    // Clock wizard instantiation for 24.576MHz audio clock
    logic clk_audio;    // 24.576MHz audio clock from clock wizard
    
    clk_wiz_1 audio_clk_gen (
        .clk_in1(clk),          // 100MHz input
        .clk_out1(clk_audio)    // 24.576MHz output
    );

    // Register offsets
    localparam logic [3:0] REG_SAW_FREQ       = 4'h0;   // Sawtooth frequency in Hz
    localparam logic [3:0] REG_SAW_DURATION   = 4'h1;   // Sawtooth duration in ms (write triggers)
    localparam logic [3:0] REG_SQUARE_FREQ    = 4'h2;   // Square frequency in Hz
    localparam logic [3:0] REG_SQUARE_DURATION = 4'h3;  // Square duration in ms (write triggers)
    
    // Clock divider constants for I2S timing
    localparam SCLK_DIV = 8;   // MCLK / 8 = SCLK (3.072 MHz)
    localparam LRCK_DIV = 64;  // SCLK periods per LRCK cycle (32 per channel)
    
    //==========================================================================
    // CPU Domain (100MHz)
    //==========================================================================
    
    // Sawtooth control registers (100MHz domain)
    logic [15:0] saw_freq_reg;           // Sawtooth frequency in Hz
    logic [15:0] saw_duration_reg;       // Sawtooth duration in milliseconds
    logic        saw_trigger_play;       // Pulse when saw duration written
    
    // Square wave control registers (100MHz domain)
    logic [15:0] square_freq_reg;        // Square frequency in Hz
    logic [15:0] square_duration_reg;    // Square duration in milliseconds
    logic        square_trigger_play;    // Pulse when square duration written
    
    // POST control
    logic        post_tone_pending;      // Power-on self test tone pending
    
    // CDC feedback to know when duration has propagated (for POST reliability)
    logic duration_ready;  // High when saw_duration_audio matches expected POST value (audio domain)
    logic duration_ready_sync1, duration_ready_sync2;  // Synchronized to CPU domain
    
    // Register interface with Power-On Self Test (100MHz domain)
    always_ff @(posedge clk) begin
        if (reset) begin
            saw_freq_reg <= 16'd3000;        // POST: 3000 Hz sawtooth tone
            saw_duration_reg <= 16'd500;     // POST: 500ms duration
            saw_trigger_play <= 1'b0;
            square_freq_reg <= 16'd440;      // Default 440 Hz for square
            square_duration_reg <= 16'd0;
            square_trigger_play <= 1'b0;
            post_tone_pending <= 1'b1;       // Enable POST after reset
        end else begin
            saw_trigger_play <= 1'b0;        // Default: clear triggers
            square_trigger_play <= 1'b0;
            
            // Handle POST tone sequence (sawtooth only)
            if (post_tone_pending) begin
                if (duration_ready_sync2) begin
                    // Duration value has propagated to audio domain
                    // Now safe to trigger POST tone
                    saw_trigger_play <= 1'b1;
                    post_tone_pending <= 1'b0;
                end
                // Otherwise keep waiting for duration to propagate
            end else if (device_select && write_req) begin
                // Normal register writes (only after POST complete)
                case (register_offset)
                    REG_SAW_FREQ: begin
                        saw_freq_reg <= wdata;
                    end
                    REG_SAW_DURATION: begin
                        saw_duration_reg <= wdata;
                        saw_trigger_play <= 1'b1;  // Trigger on duration write
                    end
                    REG_SQUARE_FREQ: begin
                        square_freq_reg <= wdata;
                    end
                    REG_SQUARE_DURATION: begin
                        square_duration_reg <= wdata;
                        square_trigger_play <= 1'b1;  // Trigger on duration write
                    end
                    default: ;
                endcase
            end
        end
    end
    
    // Read interface (100MHz domain)
    always_comb begin
        rdata = 16'hFFFF;
        if (device_select && read_req) begin
            case (register_offset)
                REG_SAW_FREQ:        rdata = saw_freq_reg;
                REG_SAW_DURATION:    rdata = saw_duration_reg;
                REG_SQUARE_FREQ:     rdata = square_freq_reg;
                REG_SQUARE_DURATION: rdata = square_duration_reg;
                default:             rdata = 16'hFFFF;
            endcase
        end
    end
    
    //==========================================================================
    // Clock Domain Crossing (100MHz -> 24.576MHz)
    //==========================================================================
    
    // Simple 2-FF synchronizers for multi-bit values
    // Brief glitches during transitions are acceptable for audio parameters
    
    // CDC for sawtooth frequency value (simple 2-FF synchronizer)
    logic [15:0] saw_freq_sync1, saw_freq_sync2;
    logic [15:0] saw_freq_audio;
    
    always_ff @(posedge clk_audio) begin
        saw_freq_sync1 <= saw_freq_reg;
        saw_freq_sync2 <= saw_freq_sync1;
        saw_freq_audio <= saw_freq_sync2;  // May glitch during transition, OK for audio
    end
    
    // CDC for sawtooth duration value (simple 2-FF synchronizer)
    logic [15:0] saw_duration_sync1, saw_duration_sync2;
    logic [15:0] saw_duration_audio;
    
    always_ff @(posedge clk_audio) begin
        saw_duration_sync1 <= saw_duration_reg;
        saw_duration_sync2 <= saw_duration_sync1;
        saw_duration_audio <= saw_duration_sync2;  // May glitch during transition, OK for audio
    end
    
    // CDC for square frequency value (simple 2-FF synchronizer)
    logic [15:0] square_freq_sync1, square_freq_sync2;
    logic [15:0] square_freq_audio;
    
    always_ff @(posedge clk_audio) begin
        square_freq_sync1 <= square_freq_reg;
        square_freq_sync2 <= square_freq_sync1;
        square_freq_audio <= square_freq_sync2;  // May glitch during transition, OK for audio
    end
    
    // CDC for square duration value (simple 2-FF synchronizer)
    logic [15:0] square_duration_sync1, square_duration_sync2;
    logic [15:0] square_duration_audio;
    
    always_ff @(posedge clk_audio) begin
        square_duration_sync1 <= square_duration_reg;
        square_duration_sync2 <= square_duration_sync1;
        square_duration_audio <= square_duration_sync2;  // May glitch during transition, OK for audio
    end
    
    // In audio domain: detect when POST duration value has arrived (for sawtooth)
    always_ff @(posedge clk_audio) begin
        duration_ready <= (saw_duration_audio == 16'd500);  // POST duration value
    end
    
    // Synchronize back to CPU domain
    always_ff @(posedge clk) begin
        if (reset) begin
            duration_ready_sync1 <= 1'b0;
            duration_ready_sync2 <= 1'b0;
        end else begin
            duration_ready_sync1 <= duration_ready;
            duration_ready_sync2 <= duration_ready_sync1;
        end
    end
    
    // CDC for sawtooth trigger pulse (pulse synchronizer with handshake)
    logic saw_trigger_req_100;
    logic saw_trigger_req_sync1, saw_trigger_req_sync2, saw_trigger_req_sync3;
    logic saw_trigger_ack_audio;
    logic saw_trigger_ack_sync1, saw_trigger_ack_sync2;
    
    // Request side (100MHz) - Sawtooth
    always_ff @(posedge clk) begin
        if (reset) begin
            saw_trigger_req_100 <= 1'b0;
        end else begin
            if (saw_trigger_play && !saw_trigger_req_100 && !saw_trigger_ack_sync2) begin
                saw_trigger_req_100 <= 1'b1;
            end else if (saw_trigger_ack_sync2) begin
                saw_trigger_req_100 <= 1'b0;
            end
        end
    end
    
    // Synchronize request to audio domain - Sawtooth
    always_ff @(posedge clk_audio) begin
        saw_trigger_req_sync1 <= saw_trigger_req_100;
        saw_trigger_req_sync2 <= saw_trigger_req_sync1;
        saw_trigger_req_sync3 <= saw_trigger_req_sync2;
    end
    
    // Detect rising edge in audio domain - Sawtooth
    logic saw_trigger_pulse_audio;
    assign saw_trigger_pulse_audio = saw_trigger_req_sync2 && !saw_trigger_req_sync3;
    
    // Acknowledge in audio domain - Sawtooth
    always_ff @(posedge clk_audio) begin
        saw_trigger_ack_audio <= saw_trigger_req_sync2;
    end
    
    // Synchronize acknowledge back to 100MHz - Sawtooth
    always_ff @(posedge clk) begin
        if (reset) begin
            saw_trigger_ack_sync1 <= 1'b0;
            saw_trigger_ack_sync2 <= 1'b0;
        end else begin
            saw_trigger_ack_sync1 <= saw_trigger_ack_audio;
            saw_trigger_ack_sync2 <= saw_trigger_ack_sync1;
        end
    end
    
    // CDC for square trigger pulse (pulse synchronizer with handshake)
    logic square_trigger_req_100;
    logic square_trigger_req_sync1, square_trigger_req_sync2, square_trigger_req_sync3;
    logic square_trigger_ack_audio;
    logic square_trigger_ack_sync1, square_trigger_ack_sync2;
    
    // Request side (100MHz) - Square
    always_ff @(posedge clk) begin
        if (reset) begin
            square_trigger_req_100 <= 1'b0;
        end else begin
            if (square_trigger_play && !square_trigger_req_100 && !square_trigger_ack_sync2) begin
                square_trigger_req_100 <= 1'b1;
            end else if (square_trigger_ack_sync2) begin
                square_trigger_req_100 <= 1'b0;
            end
        end
    end
    
    // Synchronize request to audio domain - Square
    always_ff @(posedge clk_audio) begin
        square_trigger_req_sync1 <= square_trigger_req_100;
        square_trigger_req_sync2 <= square_trigger_req_sync1;
        square_trigger_req_sync3 <= square_trigger_req_sync2;
    end
    
    // Detect rising edge in audio domain - Square
    logic square_trigger_pulse_audio;
    assign square_trigger_pulse_audio = square_trigger_req_sync2 && !square_trigger_req_sync3;
    
    // Acknowledge in audio domain - Square
    always_ff @(posedge clk_audio) begin
        square_trigger_ack_audio <= square_trigger_req_sync2;
    end
    
    // Synchronize acknowledge back to 100MHz - Square
    always_ff @(posedge clk) begin
        if (reset) begin
            square_trigger_ack_sync1 <= 1'b0;
            square_trigger_ack_sync2 <= 1'b0;
        end else begin
            square_trigger_ack_sync1 <= square_trigger_ack_audio;
            square_trigger_ack_sync2 <= square_trigger_ack_sync1;
        end
    end
    
    //==========================================================================
    // Audio Domain (24.576MHz) - No reset!
    //==========================================================================
    
    // I2S clock generation
    logic [1:0] sclk_counter;      // Divide by 8 for SCLK (counts 0-3 twice per SCLK period)
    logic [4:0] lrck_counter;      // Counts SCLK periods for LRCK (0-31 per channel)
    logic       sclk_int;          // Internal SCLK
    logic       lrck_int;          // Internal LRCK
    logic       sclk_falling;      // SCLK falling edge pulse
    
    always_ff @(posedge clk_audio) begin
        // SCLK generation (MCLK / 8)
        // Count 0-3 for each half period (4 clocks HIGH, 4 clocks LOW)
        sclk_counter <= sclk_counter + 1;
        if (sclk_counter == 2'd3) begin
            sclk_int <= ~sclk_int;  // Toggle every 4 clocks
            
            // LRCK generation (count SCLK periods)
            // Increment on every SCLK toggle (both edges = 1 SCLK period)
            if (!sclk_int) begin  // Count complete SCLK periods (on rising edge)
                if (lrck_counter == 5'd31) begin
                    lrck_counter <= 5'd0;
                    lrck_int <= ~lrck_int;  // Toggle every 32 SCLK cycles (64 total for L+R)
                end else begin
                    lrck_counter <= lrck_counter + 1;
                end
            end
        end
    end
    
    // Edge detection for SCLK
    logic sclk_prev;
    always_ff @(posedge clk_audio) begin
        sclk_prev <= sclk_int;
    end
    assign sclk_falling = !sclk_int && sclk_prev;
    
    // Sawtooth duration timer (independent prescaler)
    logic [14:0] saw_ms_prescaler;     // Divide 24.576MHz to 1kHz
    logic        saw_ms_tick;          // 1ms tick pulse for sawtooth
    logic [15:0] saw_duration_counter; // Countdown timer in ms
    logic        saw_playing;          // Sawtooth playing state
    
    always_ff @(posedge clk_audio) begin
        // Generate 1kHz tick (24576 cycles = exactly 1ms at 24.576MHz)
        if (saw_ms_prescaler == 15'd24575) begin
            saw_ms_prescaler <= 15'd0;
            saw_ms_tick <= 1'b1;
        end else begin
            saw_ms_prescaler <= saw_ms_prescaler + 1;
            saw_ms_tick <= 1'b0;
        end
        
        // Duration countdown for sawtooth
        if (saw_trigger_pulse_audio && saw_duration_audio != 16'd0) begin
            // Only start playback if duration has propagated (non-zero)
            saw_duration_counter <= saw_duration_audio;
            saw_playing <= 1'b1;
            saw_ms_prescaler <= 15'd0;  // Reset prescaler for clean timing
        end else if (saw_ms_tick && saw_duration_counter != 16'd0) begin
            saw_duration_counter <= saw_duration_counter - 1;
            if (saw_duration_counter == 16'd1) begin
                saw_playing <= 1'b0;
            end
        end
    end
    
    // Square duration timer (independent prescaler)
    logic [14:0] square_ms_prescaler;     // Divide 24.576MHz to 1kHz
    logic        square_ms_tick;          // 1ms tick pulse for square
    logic [15:0] square_duration_counter; // Countdown timer in ms
    logic        square_playing;          // Square playing state
    
    always_ff @(posedge clk_audio) begin
        // Generate 1kHz tick (24576 cycles = exactly 1ms at 24.576MHz)
        if (square_ms_prescaler == 15'd24575) begin
            square_ms_prescaler <= 15'd0;
            square_ms_tick <= 1'b1;
        end else begin
            square_ms_prescaler <= square_ms_prescaler + 1;
            square_ms_tick <= 1'b0;
        end
        
        // Duration countdown for square
        if (square_trigger_pulse_audio && square_duration_audio != 16'd0) begin
            // Only start playback if duration has propagated (non-zero)
            square_duration_counter <= square_duration_audio;
            square_playing <= 1'b1;
            square_ms_prescaler <= 15'd0;  // Reset prescaler for clean timing
        end else if (square_ms_tick && square_duration_counter != 16'd0) begin
            square_duration_counter <= square_duration_counter - 1;
            if (square_duration_counter == 16'd1) begin
                square_playing <= 1'b0;
            end
        end
    end
    
    // Generate sample tick at start of each LRCK cycle (48kHz)
    logic lrck_prev;
    always_ff @(posedge clk_audio) begin
        lrck_prev <= lrck_int;
    end
    // Update sample only on LRCK rising edge (once per stereo frame)
    assign sample_tick = (lrck_int && !lrck_prev);  // Rising edge only
    
    // Sawtooth generator with phase accumulator
    logic [31:0] saw_phase_acc;           // Phase accumulator (32-bit for precision)
    logic [31:0] saw_phase_increment;     // Frequency-dependent increment
    logic signed [15:0] sawtooth_sample;  // Current sample value (signed for mixing)
    
    // Calculate phase increment for sawtooth: (freq * 2^32) / 48000
    // Approximation: freq * 89478 (~ 2^32 / 48000)
    always_comb begin
        saw_phase_increment = saw_freq_audio * 32'd89478;
    end
    
    // Phase accumulator and sawtooth generation
    always_ff @(posedge clk_audio) begin
        if (!saw_playing) begin
            saw_phase_acc <= 32'd0;
            sawtooth_sample <= 16'd0;
        end else if (sample_tick) begin
            saw_phase_acc <= saw_phase_acc + saw_phase_increment;
            // Use top 16 bits as signed sawtooth output
            sawtooth_sample <= saw_phase_acc[31:16] - 16'h8000;  // Convert to signed
        end
    end
    
    // Square wave generator with phase accumulator
    logic [31:0] square_phase_acc;        // Phase accumulator (32-bit for precision)
    logic [31:0] square_phase_increment;  // Frequency-dependent increment
    logic signed [15:0] square_sample;    // Current sample value (signed for mixing)
    
    // Calculate phase increment for square: (freq * 2^32) / 48000
    // Approximation: freq * 89478 (~ 2^32 / 48000)
    always_comb begin
        square_phase_increment = square_freq_audio * 32'd89478;
    end
    
    // Phase accumulator and square wave generation
    always_ff @(posedge clk_audio) begin
        if (!square_playing) begin
            square_phase_acc <= 32'd0;
            square_sample <= 16'd0;
        end else if (sample_tick) begin
            square_phase_acc <= square_phase_acc + square_phase_increment;
            // Use MSB for square wave (50% duty cycle)
            square_sample <= square_phase_acc[31] ? 16'h3FFF : -16'h4000;  // Symmetric around 0
        end
    end
    
    // Waveform mixing (dynamic scaling)
    logic signed [15:0] mixed_sample;
    
    always_comb begin
        if (saw_playing && square_playing) begin
            // Both playing: average to prevent overflow
            mixed_sample = (sawtooth_sample + square_sample) >>> 1;  // Arithmetic shift right
        end else if (saw_playing) begin
            // Only sawtooth playing
            mixed_sample = sawtooth_sample;
        end else if (square_playing) begin
            // Only square playing
            mixed_sample = square_sample;
        end else begin
            // Neither playing
            mixed_sample = 16'd0;
        end
    end
    
    // I2S transmitter state machine
    typedef enum logic [1:0] {
        I2S_WAIT_LRCK,
        I2S_DELAY_FIRST,
        I2S_TRANSMIT
    } i2s_state_t;
    
    i2s_state_t i2s_state;
    logic [15:0] tx_shift_reg;     // Shift register for I2S data
    logic [4:0]  bit_counter;      // Count bits 0-15
    logic        first_bit_sent;   // Track if first bit after LRCK sent
    
    always_ff @(posedge clk_audio) begin
        case (i2s_state)
            I2S_WAIT_LRCK: begin
                // Wait for LRCK edge
                if (lrck_int != lrck_prev) begin
                    tx_shift_reg <= mixed_sample;  // Use mixed output
                    bit_counter <= 5'd0;
                    first_bit_sent <= 1'b0;
                    i2s_state <= I2S_DELAY_FIRST;
                end
            end
            
            I2S_DELAY_FIRST: begin
                // Wait for first complete SCLK cycle after LRCK change
                if (sclk_falling && !first_bit_sent) begin
                    // Skip first falling edge after LRCK
                    first_bit_sent <= 1'b1;
                end else if (sclk_falling && first_bit_sent) begin
                    // Output MSB on second falling edge
                    audio_sdin <= tx_shift_reg[15];
                    tx_shift_reg <= {tx_shift_reg[14:0], 1'b0};
                    bit_counter <= 5'd1;
                    i2s_state <= I2S_TRANSMIT;
                end
            end
            
            I2S_TRANSMIT: begin
                if (sclk_falling) begin
                    if (bit_counter < 5'd16) begin
                        // Output next bit
                        audio_sdin <= tx_shift_reg[15];
                        tx_shift_reg <= {tx_shift_reg[14:0], 1'b0};
                        bit_counter <= bit_counter + 1;
                    end else begin
                        // Done with this channel, wait for next LRCK
                        audio_sdin <= 1'b0;
                        i2s_state <= I2S_WAIT_LRCK;
                    end
                end
            end
            
            default: begin
                i2s_state <= I2S_WAIT_LRCK;
            end
        endcase
    end
    
    // Output assignments
    assign audio_mclk = clk_audio;  // Direct connection
    assign audio_lrck = lrck_int;
    assign audio_sclk = sclk_int;
    // audio_sdin assigned in state machine

endmodule
