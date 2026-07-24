`timescale 1ns / 1ps
// =============================================================================
// tb_maxpool_module.v  —  Unit test for maxpool_module.v
// =============================================================================
//
// What this checks: two separate scenarios, using two separate DUT
// instances (their dimensions differ, and Verilog parameters are fixed at
// compile time, so they can't share one instance):
//
//   dut1 — a tiny 4x4, TWO-channel input, 2x2 output. Two channels (not
//   just one) matters: the real lab uses maxpool with IN_CH=8 and IN_CH=16,
//   so this checks that your channel index (ic/oc) is included correctly
//   in the address formulas. Channel 0 is positive, channel 1 is the same
//   values negated — this also checks signed comparison (an easy mistake
//   to get backwards).
//
//   dut2 — a larger 6x6, single-channel input, 3x3 output. dut1's 2x2
//   output only exercises the outer (oh/ow) loop for 2 iterations in each
//   dimension; a bug that only shows up on the 3rd+ iteration (e.g. a
//   counter that isn't reset correctly after wrapping) would not be caught
//   by dut1 alone.
//
// dut1 input (channel 0 / channel 1):
//    1  2  3  4        -1  -2  -3  -4
//    5  6  7  8        -5  -6  -7  -8
//    9 10 11 12        -9 -10 -11 -12
//   13 14 15 16       -13 -14 -15 -16
// dut1 expected output (channel-last, 2x2x2):
//   channel 0:  6  8      channel 1:  -1  -3
//              14 16                  -9 -11
//
// dut2 input (single channel, value = row*6 + col + 1):
//    1  2  3  4  5  6
//    7  8  9 10 11 12
//   13 14 15 16 17 18
//   19 20 21 22 23 24
//   25 26 27 28 29 30
//   31 32 33 34 35 36
// dut2 expected output (3x3):
//    8 10 12
//   20 22 24
//   32 34 36
//
// Runtime: a few hundred clock cycles total across both DUTs — effectively
// instant to run.
//
// How to run: add this file plus ../../src/maxpool_module.v as simulation
// sources, then run the simulation. Read the PASS/FAIL lines in the log.
// =============================================================================

module tb_maxpool_module;

localparam CLK_PERIOD = 10;

// ---------------------------------------------------------------------------
// dut1 — 4x4, 2 channels (channel-index / sign-comparison check)
// ---------------------------------------------------------------------------
localparam D1_IN_H  = 4;
localparam D1_IN_W  = 4;
localparam D1_IN_CH = 2;

reg clk;
reg  rst1, start1;
wire done1;
wire [15:0]        in_addr1;
wire signed [7:0]  in_data1;
reg  signed [7:0]  in_mem1 [0:D1_IN_H*D1_IN_W*D1_IN_CH-1];
wire [15:0]        out_addr1;
wire signed [7:0]  out_data1;
wire               out_we1;
reg  signed [7:0]  out_mem1 [0:7];

assign in_data1 = in_mem1[in_addr1];

maxpool_module #(.IN_H(D1_IN_H), .IN_W(D1_IN_W), .IN_CH(D1_IN_CH)) dut1 (
    .clk(clk), .rst(rst1), .start(start1), .done(done1),
    .in_addr(in_addr1), .in_data(in_data1),
    .out_addr(out_addr1), .out_data(out_data1), .out_we(out_we1)
);

always @(posedge clk) begin
    if (out_we1) out_mem1[out_addr1] <= out_data1;
end

// ---------------------------------------------------------------------------
// dut2 — 6x6, 1 channel (larger-scale / outer-loop iteration check)
// ---------------------------------------------------------------------------
localparam D2_IN_H  = 6;
localparam D2_IN_W  = 6;
localparam D2_IN_CH = 1;

reg  rst2, start2;
wire done2;
wire [15:0]        in_addr2;
wire signed [7:0]  in_data2;
reg  signed [7:0]  in_mem2 [0:D2_IN_H*D2_IN_W*D2_IN_CH-1];
wire [15:0]        out_addr2;
wire signed [7:0]  out_data2;
wire               out_we2;
reg  signed [7:0]  out_mem2 [0:8];

assign in_data2 = in_mem2[in_addr2];

maxpool_module #(.IN_H(D2_IN_H), .IN_W(D2_IN_W), .IN_CH(D2_IN_CH)) dut2 (
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

task check1(input [2:0] idx, input signed [7:0] expected);
    begin
        if (out_mem1[idx] === expected)
            $display("  PASS  dut1 out[%0d] = %0d", idx, out_mem1[idx]);
        else begin
            $display("  FAIL  dut1 out[%0d] = %0d, expected %0d", idx, out_mem1[idx], expected);
            errors = errors + 1;
        end
    end
endtask

task check2(input [3:0] idx, input signed [7:0] expected);
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
    $display("  tb_maxpool_module — testing maxpool_module.v");
    $display("=========================================");

    // ---- dut1: fill 4x4x2 input ----
    for (r = 0; r < D1_IN_H; r = r + 1) begin
        for (c = 0; c < D1_IN_W; c = c + 1) begin
            in_mem1[r*D1_IN_W*D1_IN_CH + c*D1_IN_CH + 0] =  (r*D1_IN_W + c + 1);
            in_mem1[r*D1_IN_W*D1_IN_CH + c*D1_IN_CH + 1] = -(r*D1_IN_W + c + 1);
        end
    end

    // ---- dut2: fill 6x6x1 input ----
    for (r = 0; r < D2_IN_H; r = r + 1)
        for (c = 0; c < D2_IN_W; c = c + 1)
            in_mem2[r*D2_IN_W + c] = r*D2_IN_W + c + 1;

    // Reset both DUTs together
    rst1 = 1; start1 = 0;
    rst2 = 1; start2 = 0;
    repeat (2) @(posedge clk);
    @(negedge clk); rst1 = 0; rst2 = 0;

    // Start both DUTs together — they run independently and in parallel
    @(negedge clk); start1 = 1; start2 = 1;
    @(posedge clk);
    @(negedge clk); start1 = 0; start2 = 0;

    // done1/done2 are each only high for a single cycle, and the two DUTs
    // have different latencies (different IN_H/IN_W/IN_CH), so their done
    // pulses do NOT necessarily land on the same cycle — waiting for both
    // to be high AT THE SAME TIME would hang forever. Instead, latch each
    // one independently the first time it pulses, and wait for both
    // latches to be set.
    done1_seen = 0;
    done2_seen = 0;
    cnt = 0;
    while (!(done1_seen && done2_seen) && cnt < 300) begin
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
        $display("--- dut1: 4x4, 2 channels ---");
        check1(0, 6);    // (oh=0,ow=0,ch=0): max(1,2,5,6)
        check1(1, -1);   // (oh=0,ow=0,ch=1): max(-1,-2,-5,-6)
        check1(2, 8);    // (oh=0,ow=1,ch=0): max(3,4,7,8)
        check1(3, -3);   // (oh=0,ow=1,ch=1): max(-3,-4,-7,-8)
        check1(4, 14);   // (oh=1,ow=0,ch=0): max(9,10,13,14)
        check1(5, -9);   // (oh=1,ow=0,ch=1): max(-9,-10,-13,-14)
        check1(6, 16);   // (oh=1,ow=1,ch=0): max(11,12,15,16)
        check1(7, -11);  // (oh=1,ow=1,ch=1): max(-11,-12,-15,-16)
    end

    if (done2_seen) begin
        $display("--- dut2: 6x6, 1 channel (3x3 output) ---");
        check2(0, 8);    check2(1, 10);   check2(2, 12);
        check2(3, 20);   check2(4, 22);   check2(5, 24);
        check2(6, 32);   check2(7, 34);   check2(8, 36);
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
