`timescale 1ns / 1ps
// =============================================================================
// maxpool_module.v  —  2x2 Max Pooling, stride 2
// =============================================================================
// For a detailed explanation of this module, see Section 4 of the lab
// document.
// Output dimensions: OUT_H = IN_H/2, OUT_W = IN_W/2  (integer division)
// =============================================================================

module maxpool_module #(
    parameter IN_H  = 26,   // input height  (Conv1 output: 28-2=26)
    parameter IN_W  = 26,   // input width
    parameter IN_CH = 8     // channels (unchanged by pooling)
)(
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    output reg               done,

    // Input feature map (1-cycle read latency)
    output reg  [15:0]           in_addr,
    input  wire signed [7:0]     in_data,

    // Output feature map (write port)
    output reg  [15:0]           out_addr,
    output reg  signed [7:0]     out_data,
    output reg                   out_we
);

// ---------------------------------------------------------------------------
// DO NOT MODIFY
// ---------------------------------------------------------------------------
localparam OUT_H = IN_H / 2;
localparam OUT_W = IN_W / 2;

// Loop counters
reg [15:0] r_oh, r_ow, r_oc;    // which output pixel (row, col, channel) we're computing
reg [0:0]  r_kh, r_kw;          // position within the current 2x2 window: 0 or 1

// Running maximum register — holds "biggest value seen in this window so far"
reg signed [7:0] cur_max;

// FSM states
localparam S_IDLE  = 2'd0,
           S_FETCH = 2'd1,   // register address for window pixel (kh, kw)
           S_READ  = 2'd2,   // in_data valid; update cur_max; advance kh/kw
           S_WRITE = 2'd3;   // write cur_max; advance oc/ow/oh

reg [1:0] state;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state   <= S_IDLE;
        done    <= 1'b0;
        out_we  <= 1'b0;
        r_oh <= 0; r_ow <= 0; r_oc <= 0;
        r_kh <= 1'b0; r_kw <= 1'b0;
        cur_max  <= 8'sd0;
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
                    r_oh <= 0; r_ow <= 0; r_oc <= 0;
                    r_kh <= 1'b0; r_kw <= 1'b0;
                    state <= S_FETCH;
                end
            end

            // ----------------------------------------------------------------
            // Input address of window pixel (r_oh*2+r_kh, r_ow*2+r_kw),
            // channel r_oc — given, using the layout formula above.
            S_FETCH: begin
                in_addr <= (r_oh*2 + r_kh) * IN_W * IN_CH + (r_ow*2 + r_kw) * IN_CH + r_oc;
                state   <= S_READ;
            end

            // ----------------------------------------------------------------
            // TODO #1: update cur_max with in_data (first window pixel loads
            // directly, later ones only replace if larger). See lab
            // document, Section 4.1.
            S_READ: begin
                // TODO #1: write Verilog code here that updates cur_max
                // (an if/else based on in_data and r_kh/r_kw — see the
                // explanation above)

                // Advance 2x2 window: kw -> kh  (DO NOT MODIFY)
                if (r_kw == 1'b0) begin
                    r_kw  <= 1'b1;
                    state <= S_FETCH;
                end else begin
                    r_kw <= 1'b0;
                    if (r_kh == 1'b0) begin
                        r_kh  <= 1'b1;
                        state <= S_FETCH;
                    end else begin
                        r_kh  <= 1'b0;
                        state <= S_WRITE;   // all 4 pixels read
                    end
                end
            end

            // ----------------------------------------------------------------
            // Output address for pixel (r_oh, r_ow), channel r_oc — given,
            // using the layout formula above.
            S_WRITE: begin
                out_addr <= r_oh * OUT_W * IN_CH + r_ow * IN_CH + r_oc;
                out_data <= cur_max;
                out_we   <= 1'b1;

                // Advance outer loop: oc -> ow -> oh  (DO NOT MODIFY)
                if (r_oc < IN_CH - 1) begin
                    r_oc  <= r_oc + 1;
                    state <= S_FETCH;
                end else begin
                    r_oc <= 0;
                    if (r_ow < OUT_W - 1) begin
                        r_ow  <= r_ow + 1;
                        state <= S_FETCH;
                    end else begin
                        r_ow <= 0;
                        if (r_oh < OUT_H - 1) begin
                            r_oh  <= r_oh + 1;
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