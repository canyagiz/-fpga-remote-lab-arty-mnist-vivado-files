`timescale 1ns / 1ps
// =============================================================================
// tb_fc_module.v  —  Unit test for fc_module.v
// =============================================================================
//
// What this checks: a tiny fully-connected layer, IN_SIZE=4 -> OUT_SIZE=3,
// with SHIFT=2 and weights/bias chosen so this one test exercises several
// things at once:
//   - negative weights AND a negative input value, confirming negative
//     numbers propagate correctly through the multiply-accumulate (an
//     all-positive test, like a simpler test might use, would not exercise
//     this at all)
//   - a non-zero SHIFT (the real lab uses SHIFT=8 and SHIFT=9; SHIFT=0
//     can't tell you if the shift direction/amount is actually implemented)
//   - both saturation boundaries: output 1 is engineered to overflow high
//     (must clamp to +127) and output 2 to overflow low (must clamp to
//     -128), output 0 stays in range (must NOT be clamped)
//
// Input vector: [3, -2, 5, -4]
// Weights (see fc_unit_test_weights.mem, one row per output):
//   output 0: [ 1, -1,  1, -1]   bias =    0
//   output 1: [ 2,  2,  2,  2]   bias = 2000
//   output 2: [-1, -1, -1, -1]   bias = -2000
//
// Expected math:
//   output 0: acc = 0    + (3*1 + -2*-1 + 5*1 + -4*-1)  = 0    + 14 = 14
//             14 >>> 2 = 3   (in range, no clamp)                -> 3
//   output 1: acc = 2000 + (3*2 + -2*2  + 5*2 + -4*2)   = 2000 + 4  = 2004
//             2004 >>> 2 = 501 (> 127, clamp)                    -> 127
//   output 2: acc = -2000+ (3*-1 + -2*-1 + 5*-1 + -4*-1) = -2000 + -2 = -2002
//             -2002 >>> 2 = -501 (< -128, clamp)                 -> -128
//
// Expected output: [3, 127, -128]
//
// Runtime: ~27 clock cycles (OUT_SIZE * IN_SIZE * 2 + OUT_SIZE) —
// effectively instant to run.
//
// How to run: add this file, ../../src/fc_module.v, fc_unit_test_weights.mem
// and fc_unit_test_bias.mem as simulation sources, and set the simulation
// working directory to this folder (unit_tests/) so the .mem files are
// found by their relative names.
// =============================================================================

module tb_fc_module;

localparam CLK_PERIOD = 10;
localparam IN_SIZE  = 4;
localparam OUT_SIZE = 3;

reg clk, rst, start;
wire done;

wire [15:0]        in_addr;
wire signed [7:0]  in_data;
reg  signed [7:0]  in_mem [0:IN_SIZE-1];

wire [15:0]        out_addr;
wire signed [7:0]  out_data;
wire               out_we;
reg  signed [7:0]  out_mem [0:OUT_SIZE-1];

assign in_data = in_mem[in_addr];

fc_module #(
    .IN_SIZE(IN_SIZE), .OUT_SIZE(OUT_SIZE), .SHIFT(2),
    .W_FILE("fc_unit_test_weights.mem"),
    .B_FILE("fc_unit_test_bias.mem")
) dut (
    .clk(clk), .rst(rst), .start(start), .done(done),
    .in_addr(in_addr), .in_data(in_data),
    .out_addr(out_addr), .out_data(out_data), .out_we(out_we)
);

always @(posedge clk) begin
    if (out_we) out_mem[out_addr] <= out_data;
end

initial clk = 0;
always #(CLK_PERIOD / 2) clk = ~clk;

integer errors;
integer cnt;
reg     done_seen;

task check(input [1:0] idx, input signed [7:0] expected);
    begin
        if (out_mem[idx] === expected)
            $display("  PASS  out[%0d] = %0d", idx, out_mem[idx]);
        else begin
            $display("  FAIL  out[%0d] = %0d, expected %0d", idx, out_mem[idx], expected);
            errors = errors + 1;
        end
    end
endtask

initial begin
    errors = 0;
    $display("=========================================");
    $display("  tb_fc_module — testing fc_module.v");
    $display("=========================================");

    in_mem[0] = 3; in_mem[1] = -2; in_mem[2] = 5; in_mem[3] = -4;

    rst = 1; start = 0;
    repeat (2) @(posedge clk);
    @(negedge clk); rst = 0;

    @(negedge clk); start = 1;
    @(posedge clk);
    @(negedge clk); start = 0;

    cnt = 0;
    while (!done && cnt < 200) begin
        @(posedge clk);
        cnt = cnt + 1;
    end
    if (!done) begin
        $display("  FAIL  Timed out waiting for done — module never finished.");
        errors = errors + 1;
    end
    done_seen = done;   // done is only high for 1 cycle — latch it now,
                         // before it clears on the next edge below.

    // The last out_we pulses in the very same cycle as done. The out_mem
    // capture block above (always @(posedge clk) if (out_we) ...) needs one
    // more clock edge to register that final write, so wait one more cycle
    // before checking results.
    @(posedge clk);

    if (done_seen) begin
        check(0, 3);     // in range, no clamp
        check(1, 127);   // clamps high
        check(2, -128);  // clamps low
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
