`timescale 1ns / 1ps
// =============================================================================
// tb_relu_module.v  —  Exhaustive unit test for relu_module.v
// =============================================================================
//
// What this checks: relu_module.v is purely combinational and only has 256
// possible 8-bit inputs, so this test checks ALL of them (not just a
// sample) against the mathematical definition: output = max(0, input).
//
// Runtime: instant (256 combinational checks, no clock cycles needed).
//
// How to run: add this file plus ../../src/relu_module.v as simulation
// sources, then run the simulation. Read the PASS/FAIL lines in the log.
// =============================================================================

module tb_relu_module;

reg  signed [7:0] data_in;
wire signed [7:0] data_out;

relu_module #(.WIDTH(8)) dut (
    .data_in  (data_in),
    .data_out (data_out)
);

integer errors;
integer i;
reg signed [7:0] expected;

initial begin
    errors = 0;
    $display("=========================================");
    $display("  tb_relu_module — testing relu_module.v");
    $display("  (exhaustive: all 256 possible 8-bit inputs)");
    $display("=========================================");

    for (i = 0; i < 256; i = i + 1) begin
        data_in = i[7:0];
        expected = data_in[7] ? 8'sd0 : data_in;  // negative -> 0, else pass through
        #1;

        if (data_out !== expected) begin
            $display("  FAIL  relu(%0d) = %0d, expected %0d", data_in, data_out, expected);
            errors = errors + 1;
        end
    end

    if (errors == 0)
        $display("  PASS  all 256 inputs produced the correct output.");

    $display("=========================================");
    if (errors == 0)
        $display("  ALL CHECKS PASSED");
    else
        $display("  FAILED: %0d / 256 check(s) did not pass.", errors);
    $display("=========================================");

    $finish;
end

endmodule
