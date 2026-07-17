`timescale 1ns / 1ps
// =============================================================================
// tb_uart_rx.v — standalone testbench for uart_rx_module.v
//
// Drives `rx` with a REAL 115200-baud, 8N1 bit-banged stream (bit period
// computed independently from the DUT's own internal 40MHz/16x-oversample
// quantization), and checks that img_byte/img_idx/img_byte_we/img_done come
// out correctly aligned.
// =============================================================================

module tb_uart_rx;

localparam integer N_BYTES   = 16;   // small IMG_BYTES override, just to also exercise done/wrap
localparam         CLK_PERIOD = 25;  // 40 MHz, matches clk_pl in top_module.v
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

reg [7:0] test_data [0:N_BYTES-1];
initial begin
    test_data[0]  = 8'h00; test_data[1]  = 8'hFF; test_data[2]  = 8'hA5; test_data[3]  = 8'h5A;
    test_data[4]  = 8'h81; test_data[5]  = 8'h7E; test_data[6]  = 8'h55; test_data[7]  = 8'hAA;
    test_data[8]  = 8'h01; test_data[9]  = 8'h80; test_data[10] = 8'h0F; test_data[11] = 8'hF0;
    test_data[12] = 8'h33; test_data[13] = 8'hCC; test_data[14] = 8'h96; test_data[15] = 8'h69;
end

task send_byte(input [7:0] data);
    integer i;
    begin
        rx = 1'b0; #(BIT_PERIOD);              // start bit
        for (i = 0; i < 8; i = i + 1) begin
            rx = data[i];                       // LSB first
            #(BIT_PERIOD);
        end
        rx = 1'b1; #(BIT_PERIOD);               // stop bit
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
                $display("  ERROR: byte #%0d  img_idx=%0d  expected=%0d  (MISALIGNED)",
                          rx_count, img_idx, rx_count);
                errors = errors + 1;
            end
            if (img_byte !== test_data[rx_count]) begin
                $display("  ERROR: byte #%0d  img_byte=%02h  expected=%02h",
                          rx_count, img_byte, test_data[rx_count]);
                errors = errors + 1;
            end else begin
                $display("  OK    byte #%0d = %02h  (img_idx=%0d)", rx_count, img_byte, img_idx);
            end
        end
        rx_count = rx_count + 1;
    end
    if (img_done) begin
        done_count = done_count + 1;
        $display("  [%0t ns] img_done pulsed (count=%0d)  img_idx_now=%0d (expect 0)",
                  $time, done_count, img_idx);
    end
end

initial begin
    rx = 1'b1;   // idle
    rst = 1'b1;
    rx_count = 0;
    errors = 0;
    done_count = 0;

    repeat (5) @(posedge clk);
    rst = 1'b0;
    repeat (5) @(posedge clk);

    // idle line for a bit before first byte, mimic real quiet time
    #(BIT_PERIOD * 2);

    // send all N_BYTES back-to-back (no gap), the tightest realistic case
    send_byte(test_data[0]);  send_byte(test_data[1]);  send_byte(test_data[2]);  send_byte(test_data[3]);
    send_byte(test_data[4]);  send_byte(test_data[5]);  send_byte(test_data[6]);  send_byte(test_data[7]);
    send_byte(test_data[8]);  send_byte(test_data[9]);  send_byte(test_data[10]); send_byte(test_data[11]);
    send_byte(test_data[12]); send_byte(test_data[13]); send_byte(test_data[14]); send_byte(test_data[15]);

    // settle
    repeat (50) @(posedge clk);

    $display("");
    $display("=========================================");
    if (rx_count != N_BYTES)
        $display("  FAIL: received %0d bytes, expected %0d", rx_count, N_BYTES);
    else if (done_count != 1)
        $display("  FAIL: img_done pulsed %0d times, expected 1", done_count);
    else if (errors != 0)
        $display("  FAIL: %0d mismatch(es) detected", errors);
    else
        $display("  ALL CHECKS PASSED (%0d/%0d bytes correct, img_done OK)", N_BYTES, N_BYTES);
    $display("=========================================");

    $finish;
end

initial begin
    #2_000_000;  // 16 bytes * 10 bits * ~8.68us/bit =~ 1.39ms + margin
    $display("[WATCHDOG] tb_uart_rx exceeded max time, aborting.");
    $finish;
end

endmodule
