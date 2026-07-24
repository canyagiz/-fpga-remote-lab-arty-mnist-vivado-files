`timescale 1ns / 1ps
// =============================================================================
// tb_argmax_module.v  —  Unit test for argmax_module.v
// =============================================================================
//
// What this checks: five separate scenarios, each targeting a specific way
// this module could be subtly wrong:
//   Round 1 — the maximum is in the middle of the array (basic sanity check)
//   Round 2 — the maximum is the very FIRST element (catches a loop that
//             skips or mishandles index 0)
//   Round 3 — the maximum is the very LAST element (catches a loop that
//             terminates one iteration too early)
//   Round 4 — every value is negative (catches a reset/init value that is
//             not actually the smallest possible signed number, e.g. 0
//             instead of -128 — with an all-positive test set that bug
//             would never surface)
//   Round 5 — two entries tie for the maximum value (this module's
//             reference behavior is "first occurrence wins", from the
//             strict > comparison — a >= comparison would instead report
//             the LAST occurrence, so this round also catches that mistake)
//
// Runtime: ~20 clock cycles per round (SIZE * 2) — effectively instant.
//
// How to run: add this file plus ../../src/argmax_module.v as simulation
// sources, then run the simulation. Read the PASS/FAIL lines in the log.
// =============================================================================

module tb_argmax_module;

localparam CLK_PERIOD = 10;
localparam SIZE       = 10;

reg clk, rst, start;
wire done;
wire [3:0] result;

wire [15:0]        in_addr;
wire signed [7:0]  in_data;
reg  signed [7:0]  mem [0:SIZE-1];

assign in_data = mem[in_addr];

argmax_module #(.SIZE(SIZE), .IN_WIDTH(8)) dut (
    .clk(clk), .rst(rst), .start(start), .done(done),
    .in_addr(in_addr), .in_data(in_data),
    .result(result)
);

initial clk = 0;
always #(CLK_PERIOD / 2) clk = ~clk;

integer errors;
integer cnt;
reg     done_seen;

task do_reset;
    begin
        rst = 1; start = 0;
        repeat (2) @(posedge clk);
        @(negedge clk); rst = 0;
    end
endtask

task run_and_wait;
    begin
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
        done_seen = done;
    end
endtask

task check_result(input [3:0] expected);
    begin
        if (done_seen && result === expected)
            $display("  PASS  result = %0d", result);
        else if (done_seen) begin
            $display("  FAIL  result = %0d, expected %0d", result, expected);
            errors = errors + 1;
        end
    end
endtask

initial begin
    errors = 0;
    $display("=========================================");
    $display("  tb_argmax_module — testing argmax_module.v");
    $display("=========================================");

    // ---- Round 1: max in the middle (index 8) ----
    $display("--- Round 1: max in the middle ---");
    mem[0]=1; mem[1]=2; mem[2]=3; mem[3]=4; mem[4]=5;
    mem[5]=6; mem[6]=7; mem[7]=8; mem[8]=120; mem[9]=9;
    do_reset; run_and_wait; check_result(8);

    // ---- Round 2: max is the first element (index 0) ----
    $display("--- Round 2: max at index 0 ---");
    mem[0]=100; mem[1]=1; mem[2]=2; mem[3]=3; mem[4]=4;
    mem[5]=5;   mem[6]=6; mem[7]=7; mem[8]=8; mem[9]=9;
    do_reset; run_and_wait; check_result(0);

    // ---- Round 3: max is the last element (index 9) ----
    $display("--- Round 3: max at index 9 ---");
    mem[0]=1; mem[1]=2; mem[2]=3; mem[3]=4; mem[4]=5;
    mem[5]=6; mem[6]=7; mem[7]=8; mem[8]=9; mem[9]=100;
    do_reset; run_and_wait; check_result(9);

    // ---- Round 4: all values negative, max is the least-negative one ----
    $display("--- Round 4: all-negative values ---");
    mem[0]=-10; mem[1]=-20; mem[2]=-5;  mem[3]=-30; mem[4]=-1;
    mem[5]=-15; mem[6]=-25; mem[7]=-8;  mem[8]=-12; mem[9]=-2;
    do_reset; run_and_wait; check_result(4);  // -1 at index 4 is the largest

    // ---- Round 5: a tie for the maximum — first occurrence must win ----
    $display("--- Round 5: tied maximum values ---");
    mem[0]=1; mem[1]=2; mem[2]=50; mem[3]=3; mem[4]=4;
    mem[5]=5; mem[6]=50; mem[7]=6; mem[8]=7; mem[9]=8;
    do_reset; run_and_wait; check_result(2);  // index 2, not index 6

    $display("=========================================");
    if (errors == 0)
        $display("  ALL CHECKS PASSED");
    else
        $display("  FAILED: %0d check(s) did not pass.", errors);
    $display("=========================================");

    $finish;
end

endmodule
