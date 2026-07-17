`timescale 1ns / 1ps
// =============================================================================
// top_module.v  —  MNIST CNN Inference Pipeline, Arty Z7
// =============================================================================
//
// Full pipeline (100% PL — no Zynq PS/ARM involved anywhere in this design):
//   Image → Conv1 → ReLU → MaxPool1 →
//           Conv2 → ReLU → MaxPool2 →
//           FC1   → ReLU →
//           FC2   → ArgMax → predicted digit (0-9)
//
// I/O:
//   btn0 : reset (active-high)
//   btn1 : start inference (rising-edge triggered)
//   led[3:0] : predicted digit in binary
//   led[4]   : inference running (LD4)
//   led[5]   : result ready     (LD5)
//   uart_rx  : serial input from the Raspberry Pi (real Pmod JA header),
//              8N1, 125000 baud (see uart_rx_module.v header for why not the
//              more "standard" 115200) — carries the 784-byte test image
//              directly into fmap0. No ARM core, no AXI, no shared BRAM, no
//              BOOT.BIN/FSBL: the image path is entirely PL logic.
//
// Feature map memories between stages are simple reg arrays.
// Vivado infers these as BRAM or distributed RAM automatically.
// Weights are loaded from .mem files via $readmemh at synthesis/sim time.
// To swap weight precision (Lab 2): change W_FILE/B_FILE parameters and
// re-run Generate Bitstream.
// =============================================================================

module top_module (
    input  wire        clk,
    input  wire        btn0,      // JB3 — physical reset
    input  wire        btn1,      // JB4 — start inference
    output wire [5:0]  led,       // JB: [3:0]=digit, [4]=running, [5]=ready
    input  wire        uart_rx    // JA1 — Raspberry Pi UART TX -> here
);

// =============================================================================
// Clock generation — Clocking Wizard divides the board's 125 MHz oscillator
// down to 40 MHz, which is what the CNN pipeline's MAC/accumulator logic can
// actually meet timing at (worst-case combinational delay measured at
// ~20.14 ns during implementation; 40 MHz = 25 ns period gives ~24% margin).
// Every synchronous block in this design runs on clk_pl, not the raw 125 MHz
// clk pin. rst is held until the MMCM reports lock.
// =============================================================================
wire clk_pl;
wire pll_locked;

clk_wiz_0 u_clk_wiz (
    .clk_in1  (clk),
    .clk_out1 (clk_pl),
    .reset    (1'b0),
    .locked   (pll_locked)
);

// Reset synchronizer: assert rst immediately (async) on btn0/PLL-unlock, but
// release it synchronously through 2 flops. Avoids a bare combinational
// signal fanning out to hundreds of registers' async clear pins, which risks
// a glitch on that LUT output being misread as a spurious global reset
// (Methodology rule LUTAR-1).
wire rst_async = btn0 | ~pll_locked;
(* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync;
always @(posedge clk_pl or posedge rst_async) begin
    if (rst_async) rst_sync <= 2'b11;
    else            rst_sync <= {rst_sync[0], 1'b0};
end
wire rst = rst_sync[1];

// ── BTN1 rising-edge detection ───────────────────────────────────────────────
reg btn1_r;
always @(posedge clk_pl or posedge rst) begin
    if (rst) btn1_r <= 1'b0;
    else     btn1_r <= btn1;
end
wire btn1_pulse = btn1 & ~btn1_r;

// =============================================================================
// Feature map memories  (async read, sync write — Vivado infers BRAM/LUT-RAM)
// =============================================================================
// fmap0 : input image       28×28×1  =  784 bytes   (uint8, 0-255)
// fmap1 : conv1 output      26×26×8  = 5408 bytes   (int8, raw)
// fmap2 : pool1 output      13×13×8  = 1352 bytes   (int8, relu'd by wire)
// fmap3 : conv2 output      11×11×16 = 1936 bytes   (int8, raw)
// fmap4 : pool2 output       5×5×16  =  400 bytes   (int8, relu'd by wire)
// fmap5 : fc1 output              128 bytes           (int8, raw)
// fmap6 : fc2 output               10 bytes           (int8, final scores)

reg signed [7:0] fmap0 [0:783];
reg signed [7:0] fmap1 [0:5407];
reg signed [7:0] fmap2 [0:1351];
reg signed [7:0] fmap3 [0:1935];
reg signed [7:0] fmap4 [0:399];
reg signed [7:0] fmap5 [0:127];
reg signed [7:0] fmap6 [0:9];

// =============================================================================
// Test image ROM — 10 preset MNIST images, loaded once via $readmemh.
// Replaces per-experiment UART pixel streaming: the RPi now sends a single
// index byte (0-9) instead of 784 raw pixel bytes, since streaming the full
// image proved unreliable (transfer would stall partway through, root cause
// never pinned down).
// =============================================================================
localparam NUM_TEST_IMAGES = 10;
reg [7:0] test_images [0:NUM_TEST_IMAGES*784-1];
initial $readmemh("test_images.mem", test_images);

// =============================================================================
// UART image-select loader — receives a single index byte from the
// Raspberry Pi identifying which ROM image to run. Runs entirely on clk_pl,
// so no CDC synchronizer is needed for img_done (unlike the old PS-bridge
// GPIO flag, which crossed from the PS's own clock domain).
// =============================================================================
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

// ROM-to-fmap0 copy state machine — triggered whenever a new image index
// arrives (img_done pulses right after the UART receiver gets its single
// index byte). Copies 784 bytes from test_images[selected_index*784 +: 784]
// into fmap0, one byte per cycle. image_ready mirrors the old semantics:
// cleared the instant a new index arrives, set once the 784-byte copy
// completes. Out-of-range index bytes (>= NUM_TEST_IMAGES) are ignored —
// fmap0/image_ready are left exactly as they were, rather than reading
// test_images out of bounds.
reg [3:0] selected_index;
reg       copying;
reg [9:0] copy_addr;
reg       image_ready;

always @(posedge clk_pl or posedge rst) begin
    if (rst) begin
        selected_index <= 4'd0;
        copying        <= 1'b0;
        copy_addr      <= 10'd0;
        image_ready    <= 1'b0;
    end else begin
        if (img_done) begin
            if (img_byte[3:0] < NUM_TEST_IMAGES) begin
                selected_index <= img_byte[3:0];
                copying        <= 1'b1;
                copy_addr      <= 10'd0;
                image_ready    <= 1'b0;
            end
            // else: out-of-range index, ignored — no change to fmap0/image_ready
        end else if (copying) begin
            fmap0[copy_addr] <= $signed(test_images[selected_index * 784 + copy_addr]);
            if (copy_addr == 10'd783) begin
                copying     <= 1'b0;
                image_ready <= 1'b1;
            end else begin
                copy_addr <= copy_addr + 10'd1;
            end
        end
    end
end

// Module I/O wires
// =============================================================================

// ── Conv1 ─────────────────────────────────────────────────────────────────────
wire        conv1_start, conv1_done;
wire [15:0] conv1_in_addr,  conv1_out_addr;
wire signed [7:0] conv1_in_data, conv1_out_data;
wire        conv1_out_we;

assign conv1_in_data = fmap0[conv1_in_addr];   // async read

always @(posedge clk_pl) begin
    if (conv1_out_we) fmap1[conv1_out_addr] <= conv1_out_data;
end

// ── ReLU1 (wire between fmap1 and pool1 read path) ───────────────────────────
wire [15:0] pool1_in_addr;
wire signed [7:0] pool1_in_data_raw, pool1_in_data;

assign pool1_in_data_raw = fmap1[pool1_in_addr];  // async read

relu_module #(.WIDTH(8)) u_relu1 (
    .data_in  (pool1_in_data_raw),
    .data_out (pool1_in_data)
);

// ── MaxPool1 ──────────────────────────────────────────────────────────────────
wire        pool1_start, pool1_done;
wire [15:0] pool1_out_addr;
wire signed [7:0] pool1_out_data;
wire        pool1_out_we;

always @(posedge clk_pl) begin
    if (pool1_out_we) fmap2[pool1_out_addr] <= pool1_out_data;
end

// ── Conv2 ─────────────────────────────────────────────────────────────────────
wire        conv2_start, conv2_done;
wire [15:0] conv2_in_addr,  conv2_out_addr;
wire signed [7:0] conv2_in_data, conv2_out_data;
wire        conv2_out_we;

assign conv2_in_data = fmap2[conv2_in_addr];   // async read

always @(posedge clk_pl) begin
    if (conv2_out_we) fmap3[conv2_out_addr] <= conv2_out_data;
end

// ── ReLU2 ─────────────────────────────────────────────────────────────────────
wire [15:0] pool2_in_addr;
wire signed [7:0] pool2_in_data_raw, pool2_in_data;

assign pool2_in_data_raw = fmap3[pool2_in_addr];

relu_module #(.WIDTH(8)) u_relu2 (
    .data_in  (pool2_in_data_raw),
    .data_out (pool2_in_data)
);

// ── MaxPool2 ──────────────────────────────────────────────────────────────────
wire        pool2_start, pool2_done;
wire [15:0] pool2_out_addr;
wire signed [7:0] pool2_out_data;
wire        pool2_out_we;

always @(posedge clk_pl) begin
    if (pool2_out_we) fmap4[pool2_out_addr] <= pool2_out_data;
end

// ── FC1 ───────────────────────────────────────────────────────────────────────
wire        fc1_start, fc1_done;
wire [15:0] fc1_in_addr,  fc1_out_addr;
wire signed [7:0] fc1_in_data, fc1_out_data;
wire        fc1_out_we;

assign fc1_in_data = fmap4[fc1_in_addr];       // async read

always @(posedge clk_pl) begin
    if (fc1_out_we) fmap5[fc1_out_addr] <= fc1_out_data;
end

// ── ReLU3 ─────────────────────────────────────────────────────────────────────
wire [15:0] fc2_in_addr;
wire signed [7:0] fc2_in_data_raw, fc2_in_data;

assign fc2_in_data_raw = fmap5[fc2_in_addr];

relu_module #(.WIDTH(8)) u_relu3 (
    .data_in  (fc2_in_data_raw),
    .data_out (fc2_in_data)
);

// ── FC2 ───────────────────────────────────────────────────────────────────────
wire        fc2_start, fc2_done;
wire [15:0] fc2_out_addr;
wire signed [7:0] fc2_out_data;
wire        fc2_out_we;

always @(posedge clk_pl) begin
    if (fc2_out_we) fmap6[fc2_out_addr] <= fc2_out_data;
end

// ── ArgMax ────────────────────────────────────────────────────────────────────
wire        argmax_start, argmax_done;
wire [15:0] argmax_in_addr;
wire signed [7:0] argmax_in_data;
wire [3:0]  argmax_result;

assign argmax_in_data = fmap6[argmax_in_addr]; // async read

// =============================================================================
// Module instantiations
// =============================================================================

conv_module #(
    .IN_H(28), .IN_W(28), .IN_CH(1), .OUT_CH(8),
    .SHIFT(8),
    .W_FILE("conv2d_int8_weights.mem"),
    .B_FILE("conv2d_int8_bias.mem")
) u_conv1 (
    .clk(clk_pl), .rst(rst), .start(conv1_start), .done(conv1_done),
    .in_addr(conv1_in_addr), .in_data(conv1_in_data),
    .out_addr(conv1_out_addr), .out_data(conv1_out_data), .out_we(conv1_out_we)
);

maxpool_module #(
    .IN_H(26), .IN_W(26), .IN_CH(8)
) u_pool1 (
    .clk(clk_pl), .rst(rst), .start(pool1_start), .done(pool1_done),
    .in_addr(pool1_in_addr), .in_data(pool1_in_data),
    .out_addr(pool1_out_addr), .out_data(pool1_out_data), .out_we(pool1_out_we)
);

conv_module #(
    .IN_H(13), .IN_W(13), .IN_CH(8), .OUT_CH(16),
    .SHIFT(8),
    .W_FILE("conv2d_1_int8_weights.mem"),
    .B_FILE("conv2d_1_int8_bias.mem")
) u_conv2 (
    .clk(clk_pl), .rst(rst), .start(conv2_start), .done(conv2_done),
    .in_addr(conv2_in_addr), .in_data(conv2_in_data),
    .out_addr(conv2_out_addr), .out_data(conv2_out_data), .out_we(conv2_out_we)
);

maxpool_module #(
    .IN_H(11), .IN_W(11), .IN_CH(16)
) u_pool2 (
    .clk(clk_pl), .rst(rst), .start(pool2_start), .done(pool2_done),
    .in_addr(pool2_in_addr), .in_data(pool2_in_data),
    .out_addr(pool2_out_addr), .out_data(pool2_out_data), .out_we(pool2_out_we)
);

fc_module #(
    .IN_SIZE(400), .OUT_SIZE(128),
    .SHIFT(9),
    .W_FILE("dense_int8_weights.mem"),
    .B_FILE("dense_int8_bias.mem")
) u_fc1 (
    .clk(clk_pl), .rst(rst), .start(fc1_start), .done(fc1_done),
    .in_addr(fc1_in_addr), .in_data(fc1_in_data),
    .out_addr(fc1_out_addr), .out_data(fc1_out_data), .out_we(fc1_out_we)
);

fc_module #(
    .IN_SIZE(128), .OUT_SIZE(10),
    .SHIFT(8),
    .W_FILE("dense_1_int8_weights.mem"),
    .B_FILE("dense_1_int8_bias.mem")
) u_fc2 (
    .clk(clk_pl), .rst(rst), .start(fc2_start), .done(fc2_done),
    .in_addr(fc2_in_addr), .in_data(fc2_in_data),
    .out_addr(fc2_out_addr), .out_data(fc2_out_data), .out_we(fc2_out_we)
);

argmax_module #(
    .SIZE(10), .IN_WIDTH(8)
) u_argmax (
    .clk(clk_pl), .rst(rst), .start(argmax_start), .done(argmax_done),
    .in_addr(argmax_in_addr), .in_data(argmax_in_data),
    .result(argmax_result)
);

// =============================================================================
// Pipeline FSM
// =============================================================================
localparam ST_IDLE   = 4'd0,
           ST_CONV1  = 4'd1,
           ST_POOL1  = 4'd2,
           ST_CONV2  = 4'd3,
           ST_POOL2  = 4'd4,
           ST_FC1    = 4'd5,
           ST_FC2    = 4'd6,
           ST_ARGMAX = 4'd7,
           ST_RESULT = 4'd8;

reg [3:0] pipe_state;

reg conv1_start_r, pool1_start_r, conv2_start_r, pool2_start_r;
reg fc1_start_r,   fc2_start_r,   argmax_start_r;

assign conv1_start  = conv1_start_r;
assign pool1_start  = pool1_start_r;
assign conv2_start  = conv2_start_r;
assign pool2_start  = pool2_start_r;
assign fc1_start    = fc1_start_r;
assign fc2_start    = fc2_start_r;
assign argmax_start = argmax_start_r;

always @(posedge clk_pl or posedge rst) begin
    if (rst) begin
        pipe_state     <= ST_IDLE;
        conv1_start_r  <= 1'b0; pool1_start_r  <= 1'b0;
        conv2_start_r  <= 1'b0; pool2_start_r  <= 1'b0;
        fc1_start_r    <= 1'b0; fc2_start_r    <= 1'b0;
        argmax_start_r <= 1'b0;
    end else begin
        // Default: deassert all start pulses
        conv1_start_r  <= 1'b0; pool1_start_r  <= 1'b0;
        conv2_start_r  <= 1'b0; pool2_start_r  <= 1'b0;
        fc1_start_r    <= 1'b0; fc2_start_r    <= 1'b0;
        argmax_start_r <= 1'b0;

        case (pipe_state)
            ST_IDLE:
                if (btn1_pulse && image_ready) begin
                    conv1_start_r <= 1'b1;
                    pipe_state    <= ST_CONV1;
                end

            ST_CONV1:
                if (conv1_done) begin
                    pool1_start_r <= 1'b1;
                    pipe_state    <= ST_POOL1;
                end

            ST_POOL1:
                if (pool1_done) begin
                    conv2_start_r <= 1'b1;
                    pipe_state    <= ST_CONV2;
                end

            ST_CONV2:
                if (conv2_done) begin
                    pool2_start_r <= 1'b1;
                    pipe_state    <= ST_POOL2;
                end

            ST_POOL2:
                if (pool2_done) begin
                    fc1_start_r <= 1'b1;
                    pipe_state  <= ST_FC1;
                end

            ST_FC1:
                if (fc1_done) begin
                    fc2_start_r <= 1'b1;
                    pipe_state  <= ST_FC2;
                end

            ST_FC2:
                if (fc2_done) begin
                    argmax_start_r <= 1'b1;
                    pipe_state     <= ST_ARGMAX;
                end

            ST_ARGMAX:
                if (argmax_done)
                    pipe_state <= ST_RESULT;

            ST_RESULT:
                pipe_state <= ST_IDLE;   // result latched in LED logic below

            default:
                pipe_state <= ST_IDLE;
        endcase
    end
end

// =============================================================================
// LED logic
// =============================================================================
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

assign led[3:0] = r_result;
assign led[4]   = r_inference_run;
assign led[5]   = r_result_ready;

endmodule
