`timescale 1ns / 1ps
// =============================================================================
// pin_test_top.v  —  Standalone LED pin sanity checker (NOT part of the CNN lab)
// =============================================================================
//
// Purpose: verify each of the 6 LED pins (JB header, RPi-visible) is wired to
// the FPGA pin we think it is. Lights exactly one LED at a time, walking
// led[0] -> led[1] -> ... -> led[5] -> repeat, ~1.07s per LED at 125MHz.
//
// onboard_led[3:0] mirrors led_idx onto the board's own physical LD0-LD3 LEDs
// (R14, P14, N16, M14) purely as a visual "is the design alive" diagnostic —
// TEMPORARY, not part of the real pin-mapping being tested.
//
// No external reset — the counter free-runs from 0 as soon as the bitstream
// is loaded, so behavior doesn't depend on BTN0 (which may be floating right
// now since the board is disconnected from its usual RPi wiring).
// =============================================================================

module pin_test_top (
    input  wire       clk,
    output wire [5:0] led,
    output wire [3:0] onboard_led
);

localparam TICK_BITS = 27;  // 2^27 / 125MHz ~= 1.07s per LED

reg [TICK_BITS-1:0] tick_cnt = {TICK_BITS{1'b0}};
reg [2:0]           led_idx  = 3'd0;  // 0..5

always @(posedge clk) begin
    if (tick_cnt == {TICK_BITS{1'b1}}) begin
        tick_cnt <= {TICK_BITS{1'b0}};
        led_idx  <= (led_idx == 3'd5) ? 3'd0 : led_idx + 3'd1;
    end else begin
        tick_cnt <= tick_cnt + 1'b1;
    end
end

assign led         = (6'b000001 << led_idx);
assign onboard_led = (4'b0001 << led_idx[1:0]);  // walks LD0->LD1->LD2->LD3->repeat

endmodule
