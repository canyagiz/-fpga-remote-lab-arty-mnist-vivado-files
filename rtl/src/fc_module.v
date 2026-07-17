`timescale 1ns / 1ps
// =============================================================================
// fc_module.v  —  Fully Connected Layer, INT8, parametric
// =============================================================================
//
// Computes: output[o] = bias[o] + sum_{i=0}^{IN_SIZE-1} ( input[i] * weight[o][i] )
// Then requantizes INT32 → INT8 (saturate to [-128, 127]).
// ReLU is NOT applied here — use relu.v between FC1 and FC2 in top.v.
//
// Memory layout:
//   input  : addr = i          (flat, IN_SIZE entries)
//   weights: addr = o*IN_SIZE + i   (row-major: one row per output neuron)
//   output : addr = o          (flat, OUT_SIZE entries)
//
// Architecture: serial — one MAC per 2 cycles (FETCH + MAC).
// Latency: OUT_SIZE * IN_SIZE * 2  +  OUT_SIZE (write)  cycles
//
// Typical use:
//   FC1: IN_SIZE=400, OUT_SIZE=128  -> ~102,400 cycles at chosen clock
//   FC2: IN_SIZE=128, OUT_SIZE=10   -> ~2,560 cycles
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
    output reg         done,

    // Input vector (1-cycle read latency)
    output reg  [15:0]           in_addr,
    input  wire signed [7:0]     in_data,

    // Output vector (write port)
    output reg  [15:0]           out_addr,
    output reg  signed [7:0]     out_data,
    output reg                   out_we
);

// ---------------------------------------------------------------------------
localparam W_DEPTH = OUT_SIZE * IN_SIZE;

// ---------------------------------------------------------------------------
// Weight & Bias ROMs
// ---------------------------------------------------------------------------
reg signed [7:0]  weights [0:W_DEPTH-1];
reg signed [31:0] biases  [0:OUT_SIZE-1];
initial begin
    $readmemh(W_FILE, weights);
    $readmemh(B_FILE, biases);
end

// ---------------------------------------------------------------------------
// Loop counters
// ---------------------------------------------------------------------------
reg [15:0] r_o;   // output neuron index
reg [15:0] r_i;   // input neuron index

reg signed [31:0] acc;

// ---------------------------------------------------------------------------
// Weight address: weights[o * IN_SIZE + i]
// ---------------------------------------------------------------------------
wire [31:0] w_addr = r_o * IN_SIZE + r_i;

// ---------------------------------------------------------------------------
// Requantize INT32 → INT8 (saturate, no ReLU)
// ---------------------------------------------------------------------------
wire signed [31:0] shifted = acc >>> SHIFT;
wire signed [7:0]  quant_q = (shifted <= -32'sd128) ? -8'sd128 :
                             (shifted >=  32'sd127)  ?  8'sd127 :
                             shifted[7:0];

// ---------------------------------------------------------------------------
// FSM
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
                    acc   <= biases[0];
                    state <= S_FETCH;
                end
            end

            // Register input address; data valid next cycle
            S_FETCH: begin
                in_addr <= r_i;
                state   <= S_MAC;
            end

            // MAC: accumulate, then advance inner loop (i)
            S_MAC: begin
                acc <= acc + $signed(in_data) * $signed(weights[w_addr]);

                if (r_i < IN_SIZE - 1) begin
                    r_i   <= r_i + 1;
                    state <= S_FETCH;
                end else begin
                    r_i   <= 0;
                    state <= S_WRITE;
                end
            end

            // Write output neuron, advance outer loop (o)
            S_WRITE: begin
                out_addr <= r_o;
                out_data <= quant_q;
                out_we   <= 1'b1;

                if (r_o < OUT_SIZE - 1) begin
                    r_o   <= r_o + 1;
                    acc   <= biases[r_o + 1];
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
