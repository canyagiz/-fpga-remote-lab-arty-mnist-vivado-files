`timescale 1ns / 1ps
// =============================================================================
// top_module.v  —  MNIST CNN Inference Pipeline, Arty Z7  (STUDENT STARTER)
// =============================================================================
// Full pipeline: Image -> Conv1 -> ReLU -> Pool1 -> Conv2 -> ReLU -> Pool2 ->
//                FC1 -> ReLU -> FC2 -> ArgMax -> predicted digit (0-9)
//
// For a detailed explanation of this file's structure and your two TODO
// parts, see Section 7 of the lab document. Summary: everything marked
// "DO NOT MODIFY" is fixed lab infrastructure (clock, reset, UART, LEDs) —
// leave it exactly as given. Your exercise is TODO PART 1 (module
// instantiations) and TODO PART 2 (pipeline FSM), both marked below.
// =============================================================================

module top_module (
    input  wire        clk,
    input  wire        btn0,      // JB3 — physical reset
    input  wire        btn1,      // JB4 — start inference
    output wire [5:0]  led,       // JB: [3:0]=digit, [4]=running, [5]=ready
    input  wire        uart_rx,   // JA1 — Raspberry Pi UART TX -> here

    output wire [3:0]  onboard_led,      // LD0-3 — predicted digit
    output wire        onboard_led4,     // LD4 (one RGB channel) — inference running
    output wire        onboard_led5      // LD5 (one RGB channel) — result ready
);

// #############################################################################
// #####  DO NOT MODIFY BELOW THIS LINE — FIXED LAB INFRASTRUCTURE  ##########
// #############################################################################

// Clock generation — 125 MHz board clock -> 40 MHz clk_pl (see lab doc §7).
wire clk_pl;
wire pll_locked;

clk_wiz_0 u_clk_wiz (
    .clk_in1  (clk),
    .clk_out1 (clk_pl),
    .reset    (1'b0),
    .locked   (pll_locked)
);

// Reset synchronizer: assert rst immediately (async) on btn0/PLL-unlock, but
// release it synchronously through 2 flops.
wire rst_async = btn0 | ~pll_locked;
(* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync;
always @(posedge clk_pl or posedge rst_async) begin
    if (rst_async) rst_sync <= 2'b11;
    else            rst_sync <= {rst_sync[0], 1'b0};
end
wire rst = rst_sync[1];

// BTN1 rising-edge detection
reg btn1_r;
always @(posedge clk_pl or posedge rst) begin
    if (rst) btn1_r <= 1'b0;
    else     btn1_r <= btn1;
end
wire btn1_pulse = btn1 & ~btn1_r;

// Feature map memories (async read, sync write — Vivado infers BRAM/LUT-RAM)
// fmap0: input image 28x28x1=784B | fmap1: conv1 out 26x26x8 | fmap2: pool1 out 13x13x8
// fmap3: conv2 out 11x11x16       | fmap4: pool2 out 5x5x16  | fmap5: fc1 out 128
// fmap6: fc2 out 10 (final scores)
reg signed [7:0] fmap0 [0:783];
reg signed [7:0] fmap1 [0:5407];
reg signed [7:0] fmap2 [0:1351];
reg signed [7:0] fmap3 [0:1935];
reg signed [7:0] fmap4 [0:399];
reg signed [7:0] fmap5 [0:127];
reg signed [7:0] fmap6 [0:9];

// UART image loader — receives 784 bytes from the Raspberry Pi into fmap0.
wire [9:0] img_idx;
wire [7:0] img_byte;
wire       img_byte_we;
wire       img_done;

uart_rx_module #(
    .CLK_FREQ(40_000_000), .BAUD_RATE(125_000), .IMG_BYTES(1)
) u_uart_rx (
    .clk(clk_pl), .rst(rst), .rx(uart_rx),
    .img_idx(img_idx), .img_byte(img_byte),
    .img_byte_we(img_byte_we), .img_done(img_done)
);

// Chunked pixel receiver — every UART byte is one pixel; image_ready sets
// once all 784 pixels have arrived.
reg [9:0] pixel_idx;
reg       image_ready;

always @(posedge clk_pl or posedge rst) begin
    if (rst) begin
        pixel_idx   <= 10'd0;
        image_ready <= 1'b0;
    end else begin
        if (img_byte_we) begin
            fmap0[pixel_idx] <= $signed(img_byte);
            if (pixel_idx == 10'd783) begin
                pixel_idx   <= 10'd0;
                image_ready <= 1'b1;
            end else begin
                pixel_idx   <= pixel_idx + 10'd1;
                image_ready <= 1'b0;
            end
        end
    end
end

// Module I/O wires — one set per pipeline stage, connecting fmap memories
// to the module instances you'll add in TODO PART 1 below.

// -- Conv1 --------------------------------------------------------------------
wire        conv1_start, conv1_done;
wire [15:0] conv1_in_addr,  conv1_out_addr;
wire signed [7:0] conv1_in_data, conv1_out_data;
wire        conv1_out_we;

assign conv1_in_data = fmap0[conv1_in_addr];   // async read

always @(posedge clk_pl) begin
    if (conv1_out_we) fmap1[conv1_out_addr] <= conv1_out_data;
end

// -- ReLU1 (wire between fmap1 and pool1 read path) ---------------------------
wire [15:0] pool1_in_addr;
wire signed [7:0] pool1_in_data_raw, pool1_in_data;

assign pool1_in_data_raw = fmap1[pool1_in_addr];  // async read

relu_module #(.WIDTH(8)) u_relu1 (
    .data_in  (pool1_in_data_raw),
    .data_out (pool1_in_data)
);

// -- MaxPool1 -------------------------------------------------------------------
wire        pool1_start, pool1_done;
wire [15:0] pool1_out_addr;
wire signed [7:0] pool1_out_data;
wire        pool1_out_we;

always @(posedge clk_pl) begin
    if (pool1_out_we) fmap2[pool1_out_addr] <= pool1_out_data;
end

// -- Conv2 ----------------------------------------------------------------------
wire        conv2_start, conv2_done;
wire [15:0] conv2_in_addr,  conv2_out_addr;
wire signed [7:0] conv2_in_data, conv2_out_data;
wire        conv2_out_we;

assign conv2_in_data = fmap2[conv2_in_addr];   // async read

always @(posedge clk_pl) begin
    if (conv2_out_we) fmap3[conv2_out_addr] <= conv2_out_data;
end

// -- ReLU2 ------------------------------------------------------------------------
wire [15:0] pool2_in_addr;
wire signed [7:0] pool2_in_data_raw, pool2_in_data;

assign pool2_in_data_raw = fmap3[pool2_in_addr];

relu_module #(.WIDTH(8)) u_relu2 (
    .data_in  (pool2_in_data_raw),
    .data_out (pool2_in_data)
);

// -- MaxPool2 ---------------------------------------------------------------------
wire        pool2_start, pool2_done;
wire [15:0] pool2_out_addr;
wire signed [7:0] pool2_out_data;
wire        pool2_out_we;

always @(posedge clk_pl) begin
    if (pool2_out_we) fmap4[pool2_out_addr] <= pool2_out_data;
end

// -- FC1 -----------------------------------------------------------------------
wire        fc1_start, fc1_done;
wire [15:0] fc1_in_addr,  fc1_out_addr;
wire signed [7:0] fc1_in_data, fc1_out_data;
wire        fc1_out_we;

assign fc1_in_data = fmap4[fc1_in_addr];       // async read

always @(posedge clk_pl) begin
    if (fc1_out_we) fmap5[fc1_out_addr] <= fc1_out_data;
end

// -- ReLU3 -----------------------------------------------------------------------
wire [15:0] fc2_in_addr;
wire signed [7:0] fc2_in_data_raw, fc2_in_data;

assign fc2_in_data_raw = fmap5[fc2_in_addr];

relu_module #(.WIDTH(8)) u_relu3 (
    .data_in  (fc2_in_data_raw),
    .data_out (fc2_in_data)
);

// -- FC2 -----------------------------------------------------------------------
wire        fc2_start, fc2_done;
wire [15:0] fc2_out_addr;
wire signed [7:0] fc2_out_data;
wire        fc2_out_we;

always @(posedge clk_pl) begin
    if (fc2_out_we) fmap6[fc2_out_addr] <= fc2_out_data;
end

// -- ArgMax -----------------------------------------------------------------------
wire        argmax_start, argmax_done;
wire [15:0] argmax_in_addr;
wire signed [7:0] argmax_in_data;
wire [3:0]  argmax_result;

assign argmax_in_data = fmap6[argmax_in_addr]; // async read

// #############################################################################
// #####  END OF FIXED INFRASTRUCTURE  ########################################
// #############################################################################


// =============================================================================
// TODO #1 — MODULE INSTANTIATIONS. See lab document, Section 7.1 for the
// full explanation and port list. Parameter values (fixed, from the trained
// model — do not change them):
//
//   Stage  | Module         | Parameters
//   -------|----------------|---------------------------------------------
//   Conv1  | conv_module    | IN_H=28, IN_W=28, IN_CH=1, OUT_CH=8, SHIFT=8
//          |                | W_FILE="conv2d_int8_weights.mem"
//          |                | B_FILE="conv2d_int8_bias.mem"
//   Pool1  | maxpool_module | IN_H=26, IN_W=26, IN_CH=8
//   Conv2  | conv_module    | IN_H=13, IN_W=13, IN_CH=8, OUT_CH=16, SHIFT=8
//          |                | W_FILE="conv2d_1_int8_weights.mem"
//          |                | B_FILE="conv2d_1_int8_bias.mem"
//   Pool2  | maxpool_module | IN_H=11, IN_W=11, IN_CH=16
//   FC1    | fc_module      | IN_SIZE=400, OUT_SIZE=128, SHIFT=9
//          |                | W_FILE="dense_int8_weights.mem"
//          |                | B_FILE="dense_int8_bias.mem"
//   FC2    | fc_module      | IN_SIZE=128, OUT_SIZE=10, SHIFT=8
//          |                | W_FILE="dense_1_int8_weights.mem"
//          |                | B_FILE="dense_1_int8_bias.mem"
//   ArgMax | argmax_module  | SIZE=10, IN_WIDTH=8
//
// TODO #1: instantiate u_conv1, u_pool1, u_conv2, u_pool2, u_fc1, u_fc2,
// u_argmax here.


// =============================================================================
// TODO #2 — PIPELINE FSM. See lab document, Section 7.2 for the full
// explanation. Summary: sequence the eight stages in strict order, only
// advancing once the current stage's `done` pulses:
//
//   IDLE -> (btn1_pulse && image_ready) -> CONV1 -> POOL1 -> CONV2 -> POOL2
//        -> FC1 -> FC2 -> ARGMAX -> back to IDLE
//
// TODO #2: declare pipe_state and the seven *_start_r registers, drive
// conv1_start/pool1_start/.../argmax_start from them, and write the
// always-block state machine that sequences the pipeline as described above.


// #############################################################################
// #####  DO NOT MODIFY BELOW THIS LINE — FIXED LAB INFRASTRUCTURE  ##########
// #############################################################################

// LED logic — latches the predicted digit and status flags once inference
// completes, and clears them on the next BTN1 press.
reg [3:0]  r_result;
reg        r_inference_run;
reg        r_result_ready;

always @(posedge clk_pl or posedge rst) begin
    if (rst) begin
        r_result        <= 4'd0;
        r_inference_run <= 1'b0;
        r_result_ready  <= 1'b0;
    end else begin
        // LD4: high from BTN1 press (only if an image is ready) until argmax finishes
        if (btn1_pulse && image_ready)   r_inference_run <= 1'b1;
        if (argmax_done)                 r_inference_run <= 1'b0;

        // LD5 + result: latch when argmax finishes, clear on next BTN1
        if (argmax_done) begin
            r_result       <= argmax_result;
            r_result_ready <= 1'b1;
        end
        if (btn1_pulse)   r_result_ready <= 1'b0;
    end
end

// Until the image transfer completes (image_ready==0), the LEDs show pixel
// transfer progress. Once the transfer completes (image_ready==1), the LEDs
// show the usual inference result.
assign led[3:0] = image_ready ? r_result        : pixel_idx[3:0];
assign led[4]   = image_ready ? r_inference_run : pixel_idx[4];
assign led[5]   = image_ready ? r_result_ready  : pixel_idx[5];

// Onboard physical LEDs — always the underlying result/status signals
// directly, not the transfer-progress mux.
assign onboard_led  = r_result;
assign onboard_led4 = r_inference_run;
assign onboard_led5 = r_result_ready;

endmodule