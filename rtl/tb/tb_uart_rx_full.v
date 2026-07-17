`timescale 1ns / 1ps
// Full-scale (784-byte, real IMG_BYTES) UART RX validation, real 125000 baud.
// Only prints errors + summary (784 OK-lines would be noisy).

module tb_uart_rx_full;

localparam integer N_BYTES    = 784;
localparam         CLK_PERIOD = 25;                // 40 MHz
localparam real    BIT_PERIOD = 1.0e9 / 125000.0;  // true 125000 baud, exactly 8000 ns

reg clk, rst, rx;
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

wire [9:0] img_idx;
wire [7:0] img_byte;
wire       img_byte_we;
wire       img_done;

uart_rx_module #(
    .CLK_FREQ(40_000_000), .BAUD_RATE(125_000), .IMG_BYTES(N_BYTES)
) dut (
    .clk(clk), .rst(rst), .rx(rx),
    .img_idx(img_idx), .img_byte(img_byte),
    .img_byte_we(img_byte_we), .img_done(img_done)
);

// Formula-based pseudo-random-looking byte pattern, deterministic
reg [7:0] test_data [0:N_BYTES-1];
integer gi;
initial begin
    for (gi = 0; gi < N_BYTES; gi = gi + 1)
        test_data[gi] = (gi * 8'h97 + 8'h3D) ^ gi[7:0];
end

task send_byte(input [7:0] data);
    integer i;
    begin
        rx = 1'b0; #(BIT_PERIOD);
        for (i = 0; i < 8; i = i + 1) begin
            rx = data[i];
            #(BIT_PERIOD);
        end
        rx = 1'b1; #(BIT_PERIOD);
    end
endtask

integer rx_count;
integer errors;
integer done_count;

always @(posedge clk) begin
    if (img_byte_we) begin
        if (rx_count >= N_BYTES) begin
            $display("  ERROR: extra img_byte_we pulse #%0d beyond N_BYTES", rx_count);
            errors = errors + 1;
        end else begin
            if (img_idx !== rx_count[9:0]) begin
                $display("  ERROR: byte #%0d  img_idx=%0d  expected=%0d",
                          rx_count, img_idx, rx_count);
                errors = errors + 1;
            end
            if (img_byte !== test_data[rx_count]) begin
                $display("  ERROR: byte #%0d  img_byte=%02h  expected=%02h",
                          rx_count, img_byte, test_data[rx_count]);
                errors = errors + 1;
            end
        end
        rx_count = rx_count + 1;
    end
    if (img_done) begin
        done_count = done_count + 1;
        $display("  [%0t ns] img_done pulsed (count=%0d)  img_idx=%0d (expect %0d, last byte's index)",
                  $time, done_count, img_idx, N_BYTES-1);
    end
end

integer k;
initial begin
    rx = 1'b1; rst = 1'b1; rx_count = 0; errors = 0; done_count = 0;
    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);
    #(BIT_PERIOD * 2);

    for (k = 0; k < N_BYTES; k = k + 1)
        send_byte(test_data[k]);

    repeat (50) @(posedge clk);

    $display("");
    $display("=========================================");
    if (rx_count != N_BYTES)
        $display("  FAIL: received %0d bytes, expected %0d", rx_count, N_BYTES);
    else if (done_count != 1)
        $display("  FAIL: img_done pulsed %0d times, expected 1", done_count);
    else if (errors != 0)
        $display("  FAIL: %0d mismatch(es) detected out of %0d bytes", errors, N_BYTES);
    else
        $display("  ALL CHECKS PASSED (%0d/%0d bytes correct, img_done OK)", N_BYTES, N_BYTES);
    $display("=========================================");
    $finish;
end

initial begin
    #100_000_000;  // 784*10*8000ns =~ 62.7ms + margin
    $display("[WATCHDOG] tb_uart_rx_full exceeded max time, aborting.");
    $finish;
end

endmodule
