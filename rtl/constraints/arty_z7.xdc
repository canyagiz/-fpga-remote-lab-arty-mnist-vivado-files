## =============================================================================
## arty_z7.xdc  —  Arty Z7 Constraints for MNIST CNN Inference Lab
## =============================================================================
##
## 100% PL design — no Zynq PS/ARM anywhere (image loading is a direct UART
## receiver in fabric, see uart_rx_module.v). Signals routed via Raspberry Pi:
##
## Real Pmod JB has exactly 8 signal pins: JB1=W14 JB2=Y14 JB3=T11 JB4=T10
## JB5=V16 JB6=W16 JB7=V12 JB8=W13 (pins 5/6/11/12 on the physical 12-pin
## connector are fixed GND/VCC, not usable as signals).
## Real Pmod JA has exactly 8 signal pins: JA1=Y18 JA2=Y19 JA3=Y16 JA4=Y17
## JA5=U18 JA6=U19 JA7=W18 JA8=W19.
##
##   BTN0 -> JB3 (T11)   BTN1 -> JB4 (T10)
##   LD0  -> JB1 (W14)   LD1  -> JB2 (Y14)
##   LD2  -> JB5 (V16)   LD3  -> JB6 (W16)
##   LD4  -> JB7 (V12)   LD5  -> JB8 (W13)
##   UART_RX (from RPi TX) -> JA1 (Y18)
##
## Onboard signals:
##   CLK         : 125 MHz system clock (H16, single-ended)
## =============================================================================

## ----------------------------------------------------------------------------
## System Clock — 125 MHz onboard XTAL (differential pair, use P side)
## ----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN H16  IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk_pin -period 8.000 -waveform {0 4} [get_ports { clk }]

## ----------------------------------------------------------------------------
## Buttons (RPi GPIO -> JB header -> FPGA, active-high)
## ----------------------------------------------------------------------------
## BTN0 — JB3 — physical reset
set_property -dict { PACKAGE_PIN T11  IOSTANDARD LVCMOS33 } [get_ports { btn0 }]

## BTN1 — JB4 — start inference
set_property -dict { PACKAGE_PIN T10  IOSTANDARD LVCMOS33 } [get_ports { btn1 }]

## ----------------------------------------------------------------------------
## LEDs (FPGA -> JB header -> RPi GPIO)
## ----------------------------------------------------------------------------
## LD0 — JB1 — predicted digit bit 0 (LSB)
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]

## LD1 — JB2 — predicted digit bit 1
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]

## LD2 — JB5 — predicted digit bit 2
set_property -dict { PACKAGE_PIN V16  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]

## LD3 — JB6 — predicted digit bit 3 (MSB)
set_property -dict { PACKAGE_PIN W16  IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## LD4 — JB7 — inference running indicator
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33 } [get_ports { led[4] }]

## LD5 — JB8 — result ready indicator
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports { led[5] }]

## ----------------------------------------------------------------------------
## UART RX (Raspberry Pi TX -> FPGA), real Pmod JA header
## ----------------------------------------------------------------------------
## UART_RX — JA1 — image bytes in, 8N1, 125000 baud (see uart_rx_module.v
## header: 40MHz/(115200*16) doesn't divide evenly and was measured to
## corrupt high-order data bits; 125000 divides exactly)
set_property -dict { PACKAGE_PIN Y18  IOSTANDARD LVCMOS33 } [get_ports { uart_rx }]

## ----------------------------------------------------------------------------
## Timing exceptions
## ----------------------------------------------------------------------------
## Input buttons come from RPi GPIO — slow external signals, no timing constraint
set_false_path -from [get_ports { btn0 }]
set_false_path -from [get_ports { btn1 }]

## Output LEDs drive RPi GPIO — no timing constraint on outputs
set_false_path -to [get_ports { led[*] }]

## btn0/btn1/led[*]/uart_rx have no real I/O timing relationship to any clock
## (RPi GPIO bit-banging / async serial line) — these
## set_input_delay/set_output_delay(0) declarations exist only to satisfy the
## methodology "no_input_delay"/"no_output_delay" check, which otherwise
## flags any port with no delay defined at all. The false_path constraints
## above still govern actual timing analysis on btn/led; uart_rx is
## resynchronized internally by uart_rx_module's own 2-FF synchronizer, so no
## additional timing constraint is needed on it beyond the input_delay stub.
set_input_delay  -clock [get_clocks clk_out1_clk_wiz_0] -max 0 [get_ports { btn0 btn1 uart_rx }]
set_output_delay -clock [get_clocks clk_out1_clk_wiz_0] -max 0 [get_ports { led[*] }]

## clk_wiz_0's MMCM produces TWO generated-clock definitions on its own
## CLKOUT0 and CLKFBOUT pins (clk_out1_clk_wiz_0/_1 and
## clkfbout_clk_wiz_0/_1) — a known/documented Clocking Wizard behavior, not
## something to "fix" by hand-editing the IP's constraints (they get silently
## regenerated on every IP refresh). They are the same physical signal, so
## -logically_exclusive (not -asynchronous) is the correct declaration: it
## tells STA to treat them as never-simultaneously-active duplicate
## definitions of one clock, clearing TIMING-6/TIMING-56 without changing any
## real timing relationship.
set_clock_groups -logically_exclusive \
    -group [get_clocks clk_out1_clk_wiz_0] \
    -group [get_clocks clk_out1_clk_wiz_0_1]

set_clock_groups -logically_exclusive \
    -group [get_clocks clkfbout_clk_wiz_0] \
    -group [get_clocks clkfbout_clk_wiz_0_1]
