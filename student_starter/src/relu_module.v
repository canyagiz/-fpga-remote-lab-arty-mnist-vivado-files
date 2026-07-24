`timescale 1ns / 1ps
// =============================================================================
// relu_module.v  —  ReLU activation
// =============================================================================
// For a detailed explanation of this module, see Section 2 of the lab
// document. Summary: purely combinational, no clock/state.
// =============================================================================

module relu_module #(
    parameter WIDTH = 8
)(
    input  wire signed [WIDTH-1:0] data_in,
    output wire signed [WIDTH-1:0] data_out
);

// TODO #1: drive data_out with the ReLU of data_in (see lab document,
// Section 2.1 for what that means and a hint about the sign bit).
assign data_out = {WIDTH{1'b0}};  // TODO #1: replace "{WIDTH{1'b0}}"

endmodule