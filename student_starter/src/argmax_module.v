`timescale 1ns / 1ps
// =============================================================================
// argmax_module.v  —  ArgMax layer (the very last step of the CNN)
// =============================================================================
// For a detailed explanation of this module, see Section 3 of the lab
// document. Summary: finds which of SIZE input scores is largest and
// outputs its INDEX. For MNIST: SIZE=10, output is a 4-bit digit.
// =============================================================================

module argmax_module #(
    parameter SIZE     = 10,
    parameter IN_WIDTH = 8    // input data bit-width (signed INT8)
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg          done,

    // Input vector (1-cycle read latency)
    output reg  [15:0]                in_addr,
    input  wire signed [IN_WIDTH-1:0] in_data,

    // Result: index of maximum value
    output reg  [3:0]  result        // 4 bits sufficient for 0-9
);

// ---------------------------------------------------------------------------
// DO NOT MODIFY
// ---------------------------------------------------------------------------
reg [15:0]                r_idx;      // which score we're currently looking at (0..SIZE-1)
reg [15:0]                r_max_idx;  // index of the largest score found so far
reg signed [IN_WIDTH-1:0] r_max_val;  // value of the largest score found so far

localparam S_IDLE    = 2'd0,
           S_FETCH   = 2'd1,
           S_COMPARE = 2'd2,
           S_DONE    = 2'd3;
reg [1:0] state;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state     <= S_IDLE;
        done      <= 1'b0;
        r_idx     <= 0;
        r_max_idx <= 0;
        // TODO #1: initial value of r_max_val. See lab document, Section 3.1.
        r_max_val <= {IN_WIDTH{1'b0}};  // TODO #1: replace "{IN_WIDTH{1'b0}}" with the smallest possible signed value
        result    <= 4'd0;
        in_addr   <= 16'd0;
    end else begin
        done <= 1'b0;

        case (state)

            // ----------------------------------------------------------------
            S_IDLE: begin
                if (start) begin
                    r_idx     <= 0;
                    r_max_idx <= 0;
                    // Same fix as TODO #1 above, repeated so each run starts fresh.
                    r_max_val <= {IN_WIDTH{1'b0}};  // TODO #1 (again): same replacement as above
                    state     <= S_FETCH;
                end
            end

            // ----------------------------------------------------------------
            // Ask memory for the score at the current index; value is ready
            // one cycle later, in S_COMPARE.
            S_FETCH: begin
                in_addr <= r_idx;
                state   <= S_COMPARE;
            end

            // ----------------------------------------------------------------
            // TODO #2: compare in_data against r_max_val; if larger, update
            // r_max_val AND r_max_idx. See lab document, Section 3.2.
            S_COMPARE: begin
                // TODO #2: write Verilog code here — if in_data is larger
                // than r_max_val, update BOTH r_max_val (to in_data) and
                // r_max_idx (to r_idx)

                // DO NOT MODIFY — advances to the next index, or finishes.
                if (r_idx < SIZE - 1) begin
                    r_idx <= r_idx + 1;
                    state <= S_FETCH;
                end else begin
                    state <= S_DONE;
                end
            end

            // ----------------------------------------------------------------
            // All SIZE scores have been checked. r_max_idx now holds the
            // index of the largest one — that's the predicted digit.
            S_DONE: begin
                result <= r_max_idx[3:0];
                done   <= 1'b1;
                state  <= S_IDLE;
            end

        endcase
    end
end

endmodule