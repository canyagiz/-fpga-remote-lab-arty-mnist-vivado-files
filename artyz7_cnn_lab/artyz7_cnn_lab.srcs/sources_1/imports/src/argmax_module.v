`timescale 1ns / 1ps
// =============================================================================
// argmax_module.v  —  ArgMax over SIZE values, parametric
// =============================================================================
//
// Reads SIZE values sequentially from input memory, finds the index of the
// maximum value, and outputs it as the predicted class.
//
// For MNIST: SIZE=10, output is a 4-bit digit (0-9).
//
// Architecture: serial — one read per 2 cycles (FETCH + COMPARE).
// Latency: SIZE * 2 cycles
// =============================================================================

module argmax_module #(
    parameter SIZE     = 10,
    parameter IN_WIDTH = 8    // input data bit-width (signed INT8)
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    output reg         done,

    // Input vector (1-cycle read latency)
    output reg  [15:0]               in_addr,
    input  wire signed [IN_WIDTH-1:0] in_data,

    // Result: index of maximum value
    output reg  [3:0]  result        // 4 bits sufficient for 0-9
);

// ---------------------------------------------------------------------------
reg [15:0]               r_idx;      // current read index
reg [15:0]               r_max_idx;  // index of current maximum
reg signed [IN_WIDTH-1:0] r_max_val; // current maximum value

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
        r_max_val <= {IN_WIDTH{1'b1}} << (IN_WIDTH-1); // most negative value
        result    <= 4'd0;
        in_addr   <= 16'd0;
    end else begin
        done <= 1'b0;

        case (state)

            S_IDLE: begin
                if (start) begin
                    r_idx     <= 0;
                    r_max_idx <= 0;
                    r_max_val <= {1'b1, {(IN_WIDTH-1){1'b0}}}; // -128 for INT8
                    state     <= S_FETCH;
                end
            end

            // Register address for current index
            S_FETCH: begin
                in_addr <= r_idx;
                state   <= S_COMPARE;
            end

            // Compare in_data with running maximum
            S_COMPARE: begin
                if (in_data > r_max_val) begin
                    r_max_val <= in_data;
                    r_max_idx <= r_idx;
                end

                if (r_idx < SIZE - 1) begin
                    r_idx <= r_idx + 1;
                    state <= S_FETCH;
                end else begin
                    state <= S_DONE;
                end
            end

            S_DONE: begin
                result <= r_max_idx[3:0];
                done   <= 1'b1;
                state  <= S_IDLE;
            end

        endcase
    end
end

endmodule
