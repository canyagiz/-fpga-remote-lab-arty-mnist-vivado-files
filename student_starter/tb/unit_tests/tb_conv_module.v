`timescale 1ns / 1ps
// =============================================================================
// tb_conv_module.v  —  Unit test for conv_module.v
// =============================================================================
//
// What this checks: two separate scenarios, using two separate DUT
// instances (their SHIFT parameter differs, and Verilog parameters are
// fixed at compile time, so they can't share one instance). Both use a
// tiny 5x5, TWO-channel input with TWO 3x3 filters, each filter built to
// read ONLY one input channel (weight=X on its own channel's taps,
// weight=0 on the other channel's taps) — this isolates each filter's
// result to one channel, making the expected output easy to verify by
// hand, while still checking that your channel index (ic) and filter
// index (oc) are both included correctly in the weight address formula.
// A common mistake is to get the address right for a single channel/
// filter but forget one of the "+ ic*9" / "oc*(IN_CH*9)" terms, which a
// single-channel, single-filter test would not catch.
//
// dut1 (conv_unit_test_weights.mem / _bias.mem) — SHIFT=0, all-positive,
// no saturation. Checks pure address correctness with simple, easy-to-add
// numbers:
//   channel 0, value = (row + col) mod 4:
//     0 1 2 3 0      channel 1 = channel 0 + 10 at every pixel
//     1 2 3 0 1
//     2 3 0 1 2
//     3 0 1 2 3
//     0 1 2 3 0
//   filter 0 (oc=0): weight=1 on channel 0, weight=0 on channel 1
//   filter 1 (oc=1): weight=0 on channel 0, weight=1 on channel 1
// Expected 3x3x2 output:
//   filter 0 (box-sum of channel 0):     filter 1 (channel-0 result + 90):
//     14 15 12                             104 105 102
//     15 12 13                             105 102 103
//     12 13 14                             102 103 104
//
// dut2 (conv_unit_test_weights2.mem / _bias2.mem) — SHIFT=1, negative
// weights AND negative input values (confirming negative numbers
// propagate correctly through the multiply-accumulate), and biases
// engineered to
// push filter 1's result past the negative saturation boundary in every
// output position (so the clamp-to--128 logic is actually exercised, not
// just theoretically present):
//   channel 0, value = (row + col) mod 4 (same pattern as dut1)
//   channel 1, value = -((row + col) mod 4 + 1)   (always negative)
//   filter 0 (oc=0): weight=3 on channel 0, weight=0 on channel 1, bias=0
//   filter 1 (oc=1): weight=0 on channel 0, weight=1 on channel 1, bias=-300
// Expected 3x3x2 output:
//   filter 0 (3x box-sum of ch0, >>>1):    filter 1 (saturates every position):
//     21 22 18                              -128 -128 -128
//     22 18 19                              -128 -128 -128
//     18 19 21                              -128 -128 -128
//
// If your address formulas are off by one row/column/channel/filter, some
// values will land in the wrong position or the wrong filter's output —
// compare the full grid, not just one value.
//
// Runtime: a few hundred clock cycles total across both DUTs — effectively
// instant to run.
//
// How to run: add this file, ../../src/conv_module.v, and all four
// conv_unit_test_*.mem files as simulation sources, and set the simulation
// working directory to this folder (unit_tests/) so the .mem files are
// found by their relative names.
// =============================================================================

module tb_conv_module;

localparam CLK_PERIOD = 10;
localparam IN_H   = 5;
localparam IN_W   = 5;
localparam IN_CH  = 2;
localparam OUT_CH = 2;
localparam OUT_H  = 3;
localparam OUT_W  = 3;

reg clk;

// ---------------------------------------------------------------------------
// dut1 — SHIFT=0, positive values, pure address correctness
// ---------------------------------------------------------------------------
reg  rst1, start1;
wire done1;
wire [15:0]        in_addr1;
wire signed [7:0]  in_data1;
reg  signed [7:0]  in_mem1 [0:IN_H*IN_W*IN_CH-1];
wire [15:0]        out_addr1;
wire signed [7:0]  out_data1;
wire               out_we1;
reg  signed [7:0]  out_mem1 [0:OUT_H*OUT_W*OUT_CH-1];

assign in_data1 = in_mem1[in_addr1];

conv_module #(
    .IN_H(IN_H), .IN_W(IN_W), .IN_CH(IN_CH), .OUT_CH(OUT_CH), .SHIFT(0),
    .W_FILE("conv_unit_test_weights.mem"),
    .B_FILE("conv_unit_test_bias.mem")
) dut1 (
    .clk(clk), .rst(rst1), .start(start1), .done(done1),
    .in_addr(in_addr1), .in_data(in_data1),
    .out_addr(out_addr1), .out_data(out_data1), .out_we(out_we1)
);

always @(posedge clk) begin
    if (out_we1) out_mem1[out_addr1] <= out_data1;
end

// ---------------------------------------------------------------------------
// dut2 — SHIFT=1, negative weights/inputs, saturation
// ---------------------------------------------------------------------------
reg  rst2, start2;
wire done2;
wire [15:0]        in_addr2;
wire signed [7:0]  in_data2;
reg  signed [7:0]  in_mem2 [0:IN_H*IN_W*IN_CH-1];
wire [15:0]        out_addr2;
wire signed [7:0]  out_data2;
wire               out_we2;
reg  signed [7:0]  out_mem2 [0:OUT_H*OUT_W*OUT_CH-1];

assign in_data2 = in_mem2[in_addr2];

conv_module #(
    .IN_H(IN_H), .IN_W(IN_W), .IN_CH(IN_CH), .OUT_CH(OUT_CH), .SHIFT(1),
    .W_FILE("conv_unit_test_weights2.mem"),
    .B_FILE("conv_unit_test_bias2.mem")
) dut2 (
    .clk(clk), .rst(rst2), .start(start2), .done(done2),
    .in_addr(in_addr2), .in_data(in_data2),
    .out_addr(out_addr2), .out_data(out_data2), .out_we(out_we2)
);

always @(posedge clk) begin
    if (out_we2) out_mem2[out_addr2] <= out_data2;
end

initial clk = 0;
always #(CLK_PERIOD / 2) clk = ~clk;

integer errors;
integer cnt;
integer r, c;
reg     done1_seen, done2_seen;

task check1(input [4:0] idx, input signed [7:0] expected);
    begin
        if (out_mem1[idx] === expected)
            $display("  PASS  dut1 out[%0d] = %0d", idx, out_mem1[idx]);
        else begin
            $display("  FAIL  dut1 out[%0d] = %0d, expected %0d", idx, out_mem1[idx], expected);
            errors = errors + 1;
        end
    end
endtask

task check2(input [4:0] idx, input signed [7:0] expected);
    begin
        if (out_mem2[idx] === expected)
            $display("  PASS  dut2 out[%0d] = %0d", idx, out_mem2[idx]);
        else begin
            $display("  FAIL  dut2 out[%0d] = %0d, expected %0d", idx, out_mem2[idx], expected);
            errors = errors + 1;
        end
    end
endtask

initial begin
    errors = 0;
    $display("=========================================");
    $display("  tb_conv_module — testing conv_module.v");
    $display("=========================================");

    // dut1 input: channel 0 = (row+col) mod 4, channel 1 = channel 0 + 10
    for (r = 0; r < IN_H; r = r + 1) begin
        for (c = 0; c < IN_W; c = c + 1) begin
            in_mem1[r*IN_W*IN_CH + c*IN_CH + 0] = (r + c) % 4;
            in_mem1[r*IN_W*IN_CH + c*IN_CH + 1] = (r + c) % 4 + 10;
        end
    end

    // dut2 input: channel 0 = (row+col) mod 4, channel 1 = -((row+col) mod 4 + 1)
    for (r = 0; r < IN_H; r = r + 1) begin
        for (c = 0; c < IN_W; c = c + 1) begin
            in_mem2[r*IN_W*IN_CH + c*IN_CH + 0] =  (r + c) % 4;
            in_mem2[r*IN_W*IN_CH + c*IN_CH + 1] = -((r + c) % 4 + 1);
        end
    end

    // Reset both DUTs together
    rst1 = 1; start1 = 0;
    rst2 = 1; start2 = 0;
    repeat (2) @(posedge clk);
    @(negedge clk); rst1 = 0; rst2 = 0;

    // Start both DUTs together — they run independently and in parallel
    @(negedge clk); start1 = 1; start2 = 1;
    @(posedge clk);
    @(negedge clk); start1 = 0; start2 = 0;

    // done1/done2 are each only high for a single cycle. Even though both
    // DUTs here happen to share the same latency, latch each one
    // independently the first time it pulses rather than relying on them
    // lining up on the same cycle — waiting for both to be high AT THE
    // SAME TIME is fragile and would hang if the DUTs ever had different
    // latencies.
    done1_seen = 0;
    done2_seen = 0;
    cnt = 0;
    while (!(done1_seen && done2_seen) && cnt < 2000) begin
        @(posedge clk);
        if (done1) done1_seen = 1;
        if (done2) done2_seen = 1;
        cnt = cnt + 1;
    end
    if (!done1_seen) begin
        $display("  FAIL  dut1 timed out waiting for done — module never finished.");
        errors = errors + 1;
    end
    if (!done2_seen) begin
        $display("  FAIL  dut2 timed out waiting for done — module never finished.");
        errors = errors + 1;
    end

    // The last out_we pulses in the very same cycle as done. The out_mem
    // capture blocks above need one more clock edge to register that final
    // write, so wait one more cycle before checking results.
    @(posedge clk);

    if (done1_seen) begin
        $display("--- dut1: SHIFT=0, positive values ---");
        check1(0,  14);   check1(1,  104);   // (oh=0,ow=0)
        check1(2,  15);   check1(3,  105);   // (oh=0,ow=1)
        check1(4,  12);   check1(5,  102);   // (oh=0,ow=2)
        check1(6,  15);   check1(7,  105);   // (oh=1,ow=0)
        check1(8,  12);   check1(9,  102);   // (oh=1,ow=1)
        check1(10, 13);   check1(11, 103);   // (oh=1,ow=2)
        check1(12, 12);   check1(13, 102);   // (oh=2,ow=0)
        check1(14, 13);   check1(15, 103);   // (oh=2,ow=1)
        check1(16, 14);   check1(17, 104);   // (oh=2,ow=2)
    end

    if (done2_seen) begin
        $display("--- dut2: SHIFT=1, negative values + saturation ---");
        check2(0,  21);   check2(1,  -128);  // (oh=0,ow=0)
        check2(2,  22);   check2(3,  -128);  // (oh=0,ow=1)
        check2(4,  18);   check2(5,  -128);  // (oh=0,ow=2)
        check2(6,  22);   check2(7,  -128);  // (oh=1,ow=0)
        check2(8,  18);   check2(9,  -128);  // (oh=1,ow=1)
        check2(10, 19);   check2(11, -128);  // (oh=1,ow=2)
        check2(12, 18);   check2(13, -128);  // (oh=2,ow=0)
        check2(14, 19);   check2(15, -128);  // (oh=2,ow=1)
        check2(16, 21);   check2(17, -128);  // (oh=2,ow=2)
    end

    $display("=========================================");
    if (errors == 0)
        $display("  ALL CHECKS PASSED");
    else
        $display("  FAILED: %0d check(s) did not pass.", errors);
    $display("=========================================");

    $finish;
end

endmodule
