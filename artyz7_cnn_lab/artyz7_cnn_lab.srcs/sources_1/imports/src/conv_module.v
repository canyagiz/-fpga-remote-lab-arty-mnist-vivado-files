`timescale 1ns / 1ps
// =============================================================================
// conv_module.v  —  3x3 Valid Convolution + ReLU, INT8 weights, parametric
// =============================================================================
//
// Architecture: serial (2 cycles per tap: FETCH + MAC)
// Latency     : OUT_H * OUT_W * OUT_CH * IN_CH * 9 * 2  +  overhead  cycles
//
// Memory layout — channel-last (NHWC), signed INT8:
//   input  : addr = ih * IN_W * IN_CH  +  iw * IN_CH  +  ic
//   weights: addr = oc * (IN_CH*9)  +  ic * 9  +  kh * 3  +  kw
//   output : addr = oh * OUT_W * OUT_CH  +  ow * OUT_CH  +  oc
//
// Requantization: acc (INT32) right-shifted by SHIFT bits, then clamped [0,127]
// (SHIFT = 7 accounts for INT8 weight scale of 127; tune per layer if needed)
//
// Port interface:
//   in_addr / in_data   — synchronous read (addr registered in S_FETCH,
//                          data valid in S_MAC one cycle later)
//   out_addr / out_data / out_we — synchronous write in S_WRITE
// =============================================================================

module conv_module #(
    parameter IN_H    = 28,                       // input height
    parameter IN_W    = 28,                       // input width
    parameter IN_CH   = 1,                        // input channels
    parameter OUT_CH  = 8,                        // number of filters
    parameter SHIFT   = 7,                        // requantization right-shift
    parameter W_FILE  = "conv2d_int8_weights.mem",
    parameter B_FILE  = "conv2d_int8_bias.mem"
)(
    input  wire              clk,
    input  wire              rst,    // active-high synchronous reset
    input  wire              start,  // pulse 1 cycle to begin
    output reg               done,   // pulses 1 cycle when finished

    // Input feature map (1-cycle read latency)
    output reg  [15:0]           in_addr,
    input  wire signed [7:0]     in_data,

    // Output feature map (write port)
    output reg  [15:0]           out_addr,
    output reg  signed [7:0]     out_data,
    output reg                   out_we
);

// ---------------------------------------------------------------------------
// Derived constants
// ---------------------------------------------------------------------------
localparam OUT_H   = IN_H - 2;          // valid conv: no padding, 3x3 kernel
localparam OUT_W   = IN_W - 2;
localparam W_DEPTH = OUT_CH * IN_CH * 9;

// ---------------------------------------------------------------------------
// Weight & Bias ROMs  —  plain-hex .mem files, loaded with $readmemh
// ---------------------------------------------------------------------------
reg signed [7:0]  weights [0:W_DEPTH-1];
reg signed [31:0] biases  [0:OUT_CH-1];
initial begin
    $readmemh(W_FILE, weights);
    $readmemh(B_FILE, biases);
end

// ---------------------------------------------------------------------------
// Loop counters  (16-bit for synthesis simplicity; tool trims unused bits)
// ---------------------------------------------------------------------------
reg [15:0] r_oh, r_ow, r_oc, r_ic;
reg [1:0]  r_kh, r_kw;

// ---------------------------------------------------------------------------
// Accumulator  (INT32 — never overflows for INT8 inputs x INT8 weights)
// ---------------------------------------------------------------------------
reg signed [31:0] acc;

// ---------------------------------------------------------------------------
// Combinatorial: weight ROM address
// ---------------------------------------------------------------------------
wire [15:0] w_addr = r_oc * (IN_CH * 9) + r_ic * 9 + r_kh * 3 + r_kw;

// ---------------------------------------------------------------------------
// Combinatorial: requantize INT32 → INT8  (saturate, no ReLU)
// ReLU is a separate module (relu.v) instantiated in top.v
// ---------------------------------------------------------------------------
wire signed [31:0] shifted  = acc >>> SHIFT;
wire signed [7:0]  quant_q  = (shifted <= -32'sd128) ? -8'sd128 :
                              (shifted >=  32'sd127)  ?  8'sd127 :
                              shifted[7:0];

// ---------------------------------------------------------------------------
// FSM states
// ---------------------------------------------------------------------------
localparam S_IDLE  = 2'd0,
           S_FETCH = 2'd1,   // register input pixel address
           S_MAC   = 2'd2,   // in_data valid; multiply-accumulate
           S_WRITE = 2'd3;   // write output pixel; advance outer loop

reg [1:0] state;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state    <= S_IDLE;
        done     <= 1'b0;
        out_we   <= 1'b0;
        r_oh <= 0; r_ow <= 0; r_oc <= 0; r_ic <= 0;
        r_kh <= 2'd0; r_kw <= 2'd0;
        acc      <= 32'sd0;
        in_addr  <= 16'd0;
        out_addr <= 16'd0;
        out_data <= 8'sd0;
    end else begin
        done   <= 1'b0;
        out_we <= 1'b0;

        case (state)

            // ----------------------------------------------------------------
            S_IDLE: begin
                if (start) begin
                    r_oh <= 0; r_ow <= 0; r_oc <= 0; r_ic <= 0;
                    r_kh <= 2'd0; r_kw <= 2'd0;
                    acc   <= biases[0];   // signed [7:0] -> signed [31:0]: auto sign-extends
                    state <= S_FETCH;
                end
            end

            // ----------------------------------------------------------------
            // Present pixel address; in_data will be valid next cycle (S_MAC)
            S_FETCH: begin
                in_addr <= (r_oh + r_kh) * IN_W * IN_CH
                         + (r_ow + r_kw) * IN_CH
                         + r_ic;
                state   <= S_MAC;
            end

            // ----------------------------------------------------------------
            // in_data is now valid — accumulate, then advance inner loop
            S_MAC: begin
                acc <= acc + $signed(in_data) * $signed(weights[w_addr]);

                // Advance inner loop: kw -> kh -> ic
                if (r_kw < 2'd2) begin
                    r_kw  <= r_kw + 2'd1;
                    state <= S_FETCH;
                end else begin
                    r_kw <= 2'd0;
                    if (r_kh < 2'd2) begin
                        r_kh  <= r_kh + 2'd1;
                        state <= S_FETCH;
                    end else begin
                        r_kh <= 2'd0;
                        if (r_ic < IN_CH - 1) begin
                            r_ic  <= r_ic + 1;
                            state <= S_FETCH;
                        end else begin
                            r_ic  <= 0;
                            state <= S_WRITE;   // inner loop complete
                        end
                    end
                end
            end

            // ----------------------------------------------------------------
            // Write requantized output (no ReLU — relu.v handles it in top.v)
            S_WRITE: begin
                out_addr <= r_oh * OUT_W * OUT_CH + r_ow * OUT_CH + r_oc;
                out_data <= quant_q;
                out_we   <= 1'b1;

                if (r_oc < OUT_CH - 1) begin
                    r_oc  <= r_oc + 1;
                    acc   <= biases[r_oc + 1];  // NB: uses pre-update r_oc (non-blocking)
                    state <= S_FETCH;
                end else begin
                    r_oc <= 0;
                    if (r_ow < OUT_W - 1) begin
                        r_ow  <= r_ow + 1;
                        acc   <= biases[0];
                        state <= S_FETCH;
                    end else begin
                        r_ow <= 0;
                        if (r_oh < OUT_H - 1) begin
                            r_oh  <= r_oh + 1;
                            acc   <= biases[0];
                            state <= S_FETCH;
                        end else begin
                            done  <= 1'b1;
                            state <= S_IDLE;
                        end
                    end
                end
            end

        endcase
    end
end

endmodule
