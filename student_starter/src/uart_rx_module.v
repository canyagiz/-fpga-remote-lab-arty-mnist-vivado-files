`timescale 1ns / 1ps
// =============================================================================
// uart_rx_module.v  —  Simple 8N1 UART receiver, PL-only image loader
// =============================================================================
// DO NOT MODIFY THIS FILE. It's fixed lab infrastructure, not part of the
// exercise — top_module.v instantiates it as-is. Changing it can break
// communication with the Raspberry Pi/website in ways that are very hard to
// debug from the student side.
//
// This module receives the input image directly in FPGA fabric (PL): the
// Raspberry Pi's UART TX line connects to a PL pin (real Pmod JA header),
// and this module receives bytes serially, writing each one straight into
// fmap0.
//
// Protocol: standard 8 data bits, no parity, 1 stop bit (8N1), LSB first.
// Baud rate is set by BAUD_DIV = clk_freq / baud_rate (16x oversampling).
//
// BAUD_RATE = 125_000, not the more "standard" 115_200: at CLK_FREQ=40MHz,
// 40_000_000/(125_000*16) = 20 ticks/sample EXACTLY, so there's no rounding
// error in the internal bit-timing. 115_200 would instead give 21.7
// ticks/sample, truncating to 21 — a small per-tick error that compounds
// bit-by-bit across a byte and was measured (via tb_uart_rx.v) to corrupt
// the high-order data bits of nearly every byte. The Raspberry Pi sender
// must be configured to the same 125_000 baud (pyserial supports arbitrary
// baud rates on Linux via termios2/BOTHER).
//
// After IMG_BYTES bytes have been received, img_done pulses for 1 cycle and
// img_idx/img_byte hold the final byte's write address/data for one more
// cycle (top_module latches these into fmap0 the same way as every other
// byte — no special-casing needed for the last byte).
//
// top_module.v instantiates this with IMG_BYTES=1, not 784: the Raspberry
// Pi sends the image one pixel at a time and waits for each byte to be
// acknowledged (by reading pixel_idx back over the LEDs) before sending the
// next one, rather than streaming all 784 bytes in one continuous burst.
// This module only handles the low-level UART framing for a single byte —
// img_byte_we pulsing once per byte is what top_module.v's own pixel
// receiver logic uses to advance pixel_idx and assemble the full image.
// =============================================================================

module uart_rx_module #(
    parameter CLK_FREQ  = 40_000_000,
    parameter BAUD_RATE = 125_000,
    parameter IMG_BYTES = 784
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        rx,          // serial input, idle-high

    output reg  [9:0]  img_idx,     // 0..IMG_BYTES-1, valid when img_byte_we is high
    output reg  [7:0]  img_byte,
    output reg         img_byte_we, // 1-cycle pulse: write img_byte into fmap0[img_idx]
    output reg         img_done     // 1-cycle pulse after the IMG_BYTES-th byte
);

localparam integer OVERSAMPLE = 16;
localparam integer TICKS_PER_BIT = CLK_FREQ / (BAUD_RATE * OVERSAMPLE);

// FSM state encoding — declared here (ahead of its normal "Receive FSM"
// section below) because the baud tick generator's reset condition needs
// to reference `state` and Verilog requires the declaration to appear
// before use.
localparam S_IDLE  = 2'd0,
           S_START = 2'd1,   // confirm start bit at mid-bit
           S_DATA  = 2'd2,   // shift in 8 data bits
           S_STOP  = 2'd3;   // wait out the stop bit

reg [1:0] state;

// ---------------------------------------------------------------------------
// 2-FF synchronizer for the async serial input — declared here (ahead of
// its normal section below) because the baud tick generator's reset
// condition needs to reference `rx_s`.
// ---------------------------------------------------------------------------
(* ASYNC_REG = "TRUE" *) reg rx_sync0, rx_sync1;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        rx_sync0 <= 1'b1;
        rx_sync1 <= 1'b1;
    end else begin
        rx_sync0 <= rx;
        rx_sync1 <= rx_sync0;
    end
end
wire rx_s = rx_sync1;

// ---------------------------------------------------------------------------
// Baud tick generator — one tick every TICKS_PER_BIT clk cycles (16 ticks/bit)
// ---------------------------------------------------------------------------
reg [15:0] tick_cnt;
wire       baud_tick = (tick_cnt == TICKS_PER_BIT - 1);

// Also resets the instant a start bit is detected (state==S_IDLE && !rx_s),
// so the oversampling phase is aligned to the real start-bit edge rather
// than wherever tick_cnt happened to be mid-count while idle. This check is
// kept in THIS always block (not the FSM's) so tick_cnt has exactly one
// driver — a second `tick_cnt <= ...` in the FSM block is illegal Verilog
// (multiple drivers on one reg); xsim tolerated it in behavioral simulation
// but synthesis correctly rejected it (DRC MDRV-1).
always @(posedge clk) begin
    if (rst || baud_tick || (state == S_IDLE && !rx_s))
        tick_cnt <= 16'd0;
    else
        tick_cnt <= tick_cnt + 16'd1;
end

// ---------------------------------------------------------------------------
// Receive FSM
// ---------------------------------------------------------------------------
// state/S_IDLE/S_START/S_DATA/S_STOP declared earlier (see baud tick
// generator comment above) — only the remaining FSM registers are here.
reg [3:0] sample_cnt;   // 0..15 within the current bit
reg [2:0] bit_idx;      // 0..7 data bit index
reg [7:0] shift_reg;

// Internal write-pointer, separate from the img_idx OUTPUT port. img_idx and
// img_byte_we are both registered outputs updated in the same NBA batch
// below, so a consumer clocked on the same clk (e.g. top_module.v's
// `if (img_byte_we) fmap0[img_idx] <= ...`) samples them ONE cycle after
// this always block runs — by which point, if img_idx itself had been
// incremented here, the consumer would see the NEXT byte's index instead of
// the index this byte actually belongs at (confirmed via tb_uart_rx.v: every
// byte landed one slot ahead, wrapping fmap0[0] to hold the LAST byte
// received). Keeping next_idx as the thing that increments, and latching
// img_idx <= next_idx (the pre-increment value) at the same time as
// img_byte_we, keeps img_idx frozen at the correct index for exactly the
// cycle img_byte_we is 1.
reg [9:0] next_idx;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state       <= S_IDLE;
        img_idx     <= 10'd0;
        next_idx    <= 10'd0;
        img_byte    <= 8'd0;
        img_byte_we <= 1'b0;
        img_done    <= 1'b0;
        sample_cnt  <= 4'd0;
        bit_idx     <= 3'd0;
        shift_reg   <= 8'd0;
    end else begin
        img_byte_we <= 1'b0;
        img_done    <= 1'b0;

        case (state)
            S_IDLE: begin
                if (!rx_s) begin           // falling edge = start bit begins
                    // tick_cnt reset happens in its own always block above,
                    // not here (see comment there) — avoids a second driver.
                    sample_cnt <= 4'd0;
                    state      <= S_START;
                end
            end

            S_START: if (baud_tick) begin
                if (sample_cnt == OVERSAMPLE/2 - 1) begin
                    if (!rx_s) begin        // confirmed start bit at mid-point
                        sample_cnt <= 4'd0;
                        bit_idx    <= 3'd0;
                        state      <= S_DATA;
                    end else begin
                        state      <= S_IDLE;   // glitch, not a real start bit
                    end
                end else begin
                    sample_cnt <= sample_cnt + 4'd1;
                end
            end

            S_DATA: if (baud_tick) begin
                if (sample_cnt == OVERSAMPLE - 1) begin
                    sample_cnt          <= 4'd0;
                    shift_reg[bit_idx]  <= rx_s;   // sample at mid-bit
                    if (bit_idx == 3'd7) state <= S_STOP;
                    else                 bit_idx <= bit_idx + 3'd1;
                end else begin
                    sample_cnt <= sample_cnt + 4'd1;
                end
            end

            S_STOP: if (baud_tick) begin
                if (sample_cnt == OVERSAMPLE - 1) begin
                    sample_cnt  <= 4'd0;
                    img_byte    <= shift_reg;
                    img_byte_we <= 1'b1;
                    img_idx     <= next_idx;   // freeze at THIS byte's index

                    if (next_idx == IMG_BYTES - 1) begin
                        next_idx <= 10'd0;
                        img_done <= 1'b1;
                    end else begin
                        next_idx <= next_idx + 10'd1;
                    end
                    state <= S_IDLE;
                end else begin
                    sample_cnt <= sample_cnt + 4'd1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule