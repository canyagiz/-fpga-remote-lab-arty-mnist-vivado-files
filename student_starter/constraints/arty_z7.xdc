## =============================================================================
## arty_z7.xdc  —  Pin constraints for the MNIST CNN Inference Lab (Arty Z7)

## This file tells Vivado which physical pin each signal in top_module.v
## connects to. You should not need to edit this file.

## ----------------------------------------------------------------------------
## Board clock — 125 MHz onboard oscillator
## ----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN H16  IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk_pin -period 8.000 -waveform {0 4} [get_ports { clk }]

## ----------------------------------------------------------------------------
## Buttons — driven from the Raspberry Pi over the Pmod JB header
## ----------------------------------------------------------------------------
## BTN0 — physical reset
set_property -dict { PACKAGE_PIN T11  IOSTANDARD LVCMOS33 } [get_ports { btn0 }]

## BTN1 — start inference
set_property -dict { PACKAGE_PIN T10  IOSTANDARD LVCMOS33 } [get_ports { btn1 }]

## ----------------------------------------------------------------------------
## LEDs — read by the Raspberry Pi over the Pmod JB header, shown on the website
## ----------------------------------------------------------------------------
## LD0 — predicted digit, bit 0 (LSB)
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]

## LD1 — predicted digit, bit 1
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]

## LD2 — predicted digit, bit 2
set_property -dict { PACKAGE_PIN V16  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]

## LD3 — predicted digit, bit 3 (MSB)
set_property -dict { PACKAGE_PIN W16  IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## LD4 — inference running
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33 } [get_ports { led[4] }]

## LD5 — result ready
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports { led[5] }]

## ----------------------------------------------------------------------------
## Onboard LEDs — the physical LEDs on the Arty board itself, so you can see
## the result standing at the board (same information as the LEDs above).
## LD4/LD5 are RGB LEDs; only one color channel of each is used here.
## ----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN R14  IOSTANDARD LVCMOS33 } [get_ports { onboard_led[0] }]
set_property -dict { PACKAGE_PIN P14  IOSTANDARD LVCMOS33 } [get_ports { onboard_led[1] }]
set_property -dict { PACKAGE_PIN N16  IOSTANDARD LVCMOS33 } [get_ports { onboard_led[2] }]
set_property -dict { PACKAGE_PIN M14  IOSTANDARD LVCMOS33 } [get_ports { onboard_led[3] }]

## LD4 — inference running
set_property -dict { PACKAGE_PIN L15  IOSTANDARD LVCMOS33 } [get_ports { onboard_led4 }]

## LD5 — result ready
set_property -dict { PACKAGE_PIN G14  IOSTANDARD LVCMOS33 } [get_ports { onboard_led5 }]

## ----------------------------------------------------------------------------
## UART RX — serial link from the Raspberry Pi, carries the input image
## ----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN Y18  IOSTANDARD LVCMOS33 } [get_ports { uart_rx }]

## ----------------------------------------------------------------------------
## Timing exceptions
## ----------------------------------------------------------------------------
## Buttons and UART come from off-chip (Raspberry Pi), not from a clocked
## source on this board, so normal timing analysis does not apply to them.
set_false_path -from [get_ports { btn0 }]
set_false_path -from [get_ports { btn1 }]

## LEDs are just indicator lights, not sampled by any clocked logic, so
## timing analysis does not apply to them either.
set_false_path -to [get_ports { led[*] }]
set_false_path -to [get_ports { onboard_led[*] onboard_led4 onboard_led5 }]

## Vivado requires every I/O port to have a delay value defined. These lines
## just satisfy that requirement (the false_path lines above are what
## actually matter for these signals).
set_input_delay  -clock [get_clocks clk_out1_clk_wiz_0] -max 0 [get_ports { btn0 btn1 uart_rx }]
set_output_delay -clock [get_clocks clk_out1_clk_wiz_0] -max 0 [get_ports { led[*] }]
set_output_delay -clock [get_clocks clk_out1_clk_wiz_0] -max 0 [get_ports { onboard_led[*] onboard_led4 onboard_led5 }]

## The Clocking Wizard IP (which divides the 125 MHz board clock down to the
## 40 MHz clock your design runs on) creates two internal names for the same
## physical clock signal. This tells Vivado they are the same clock, so it
## does not report a false timing conflict between them.
set_clock_groups -logically_exclusive \
    -group [get_clocks clk_out1_clk_wiz_0] \
    -group [get_clocks clk_out1_clk_wiz_0_1]

set_clock_groups -logically_exclusive \
    -group [get_clocks clkfbout_clk_wiz_0] \
    -group [get_clocks clkfbout_clk_wiz_0_1]