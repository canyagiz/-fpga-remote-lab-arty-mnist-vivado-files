`timescale 1ns / 1ps
// =============================================================================
// fc_module.v  —  Fully Connected (Dense) Layer
// =============================================================================
// For a detailed explanation of this module, see Section 5 of the lab
// document.
// =============================================================================

module fc_module #(
    parameter IN_SIZE  = 400,
    parameter OUT_SIZE = 128,
    parameter SHIFT    = 7,
    parameter W_FILE   = "fc_int8_weights.mem",
    parameter B_FILE   = "fc_int8_bias.mem"
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg          done,

    // Input vector (1-cycle read latency)
    output reg  [15:0]           in_addr,
    input  wire signed [7:0]     in_data,

    // Output vector (write port)
    output reg  [15:0]           out_addr,
    output reg  signed [7:0]     out_data,
    output reg                   out_we
);

// ---------------------------------------------------------------------------
// DO NOT MODIFY
// ---------------------------------------------------------------------------
localparam W_DEPTH = OUT_SIZE * IN_SIZE;

// Weight & Bias ROMs, loaded once at the start from the .mem files given
// to top_module.v via the W_FILE/B_FILE parameters above
reg signed [7:0]  weights [0:W_DEPTH-1];
reg signed [31:0] biases  [0:OUT_SIZE-1];
initial begin
    $readmemh(W_FILE, weights);
    $readmemh(B_FILE, biases);
end

// Loop counters
reg [15:0] r_o;   // which output neuron we're currently computing
reg [15:0] r_i;   // which input we're currently adding in

// Running total for the current output neuron
reg signed [31:0] acc;

// Weight ROM address for the (output neuron, input) pair currently being
// processed — given, using the row-major layout formula above.
wire [31:0] w_addr = r_o * IN_SIZE + r_i;

// TODO #1: requantize acc (shift + saturate) down to INT8. See lab
// document, Section 5.1.
wire signed [31:0] shifted = 32'sd0;   // TODO #1: replace "32'sd0" with an arithmetic right-shift of acc by SHIFT bits (hint: Verilog's ">>>" operator does a signed shift)
wire signed [7:0]  quant_q = 8'sd0;    // TODO #1: replace "8'sd0" with the saturated (clamped) value of "shifted"

// ---------------------------------------------------------------------------
// FSM (do not modify state transitions)
// ---------------------------------------------------------------------------
localparam S_IDLE  = 2'd0,
           S_FETCH = 2'd1,
           S_MAC   = 2'd2,
           S_WRITE = 2'd3;
reg [1:0] state;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state    <= S_IDLE;
        done     <= 1'b0;
        out_we   <= 1'b0;
        r_o <= 0; r_i <= 0;
        acc      <= 32'sd0;
        in_addr  <= 16'd0;
        out_addr <= 16'd0;
        out_data <= 8'sd0;
    end else begin
        done   <= 1'b0;
        out_we <= 1'b0;

        case (state)

            S_IDLE: begin
                if (start) begin
                    r_o   <= 0;
                    r_i   <= 0;
                    acc   <= biases[0];   // start each output neuron's total from its bias
                    state <= S_FETCH;
                end
            end

            // Register input address; data valid next cycle
            S_FETCH: begin
                in_addr <= r_i;
                state   <= S_MAC;
            end

            // ----------------------------------------------------------------
            // TODO #2: accumulate this cycle's contribution into acc — see
            // lab document, Section 5.2 for the full explanation, including
            // why both operands need to be wrapped in $signed(...).
            S_MAC: begin
                // TODO #2: write the multiply-accumulate here

                // Advance inner loop (i)  (DO NOT MODIFY)
                if (r_i < IN_SIZE - 1) begin
                    r_i   <= r_i + 1;
                    state <= S_FETCH;
                end else begin
                    r_i   <= 0;
                    state <= S_WRITE;
                end
            end

            // Write output neuron, advance outer loop (o)  (DO NOT MODIFY)
            S_WRITE: begin
                out_addr <= r_o;
                out_data <= quant_q;
                out_we   <= 1'b1;

                if (r_o < OUT_SIZE - 1) begin
                    r_o   <= r_o + 1;
                    acc   <= biases[r_o + 1];  // start the next output neuron's total from its own bias
                    state <= S_FETCH;
                end else begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
            end

        endcase
    end
end

endmodule