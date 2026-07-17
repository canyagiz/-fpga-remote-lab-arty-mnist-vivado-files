`timescale 1ns / 1ps
// =============================================================================
// relu_module.v  —  ReLU activation, combinatorial, parametric bit-width
// =============================================================================
//
// output = max(0, input)
//
// For INT8: negative values (MSB=1) map to 0, positive values pass through.
// No clock needed — purely combinatorial.
//
// Usage in top-level: instantiate between conv output and maxpool input.
// The conv module writes raw (requantized) INT8 to a feature map memory;
// this module sits on the read-data path so maxpool always sees ReLU'd values.
//
// Example wiring in top.v:
//   wire signed [7:0] conv_raw;   // data read from conv output memory
//   wire signed [7:0] relu_out;   // goes into maxpool's in_data port
//   relu #(.WIDTH(8)) u_relu (.data_in(conv_raw), .data_out(relu_out));
// =============================================================================

module relu_module #(
    parameter WIDTH = 8
)(
    input  wire signed [WIDTH-1:0] data_in,
    output wire signed [WIDTH-1:0] data_out
);

// If sign bit is 1 (negative), output 0; otherwise pass through.
assign data_out = data_in[WIDTH-1] ? {WIDTH{1'b0}} : data_in;

endmodule
