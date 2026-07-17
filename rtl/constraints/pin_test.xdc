## =============================================================================
## pin_test.xdc  —  Constraints for pin_test_top.v (LED pin sanity check)
## =============================================================================
##
## All 6 LEDs now use REAL Pmod JB header pins (verified against Digilent's
## official Arty-Z7-20-Master.xdc). Our earlier "JB1..JB8" comments in
## arty_z7.xdc were wrong labels — most of those pins are actually on the
## ChipKit header, not Pmod JB. Real Pmod JB has exactly 8 pins:
##   JB1=W14  JB2=Y14  JB3=T11  JB4=T10  JB5=V16  JB6=W16  JB7=V12  JB8=W13
## btn0(T11)/btn1(T10) already sat on real JB3/JB4 pins (lucky/correct).
## led[4]=V12 already sat on real JB7 (lucky/correct). All other LEDs are
## remapped here to the remaining real JB pins (JB1, JB2, JB5, JB6, JB8).
## =============================================================================

## System Clock
set_property -dict { PACKAGE_PIN H16  IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk_pin -period 8.000 -waveform {0 4} [get_ports { clk }]

## LEDs — all on real Pmod JB pins
set_property -dict { PACKAGE_PIN W14  IOSTANDARD LVCMOS33 } [get_ports { led[0] }]  ; # JB1
set_property -dict { PACKAGE_PIN Y14  IOSTANDARD LVCMOS33 } [get_ports { led[1] }]  ; # JB2
set_property -dict { PACKAGE_PIN V16  IOSTANDARD LVCMOS33 } [get_ports { led[2] }]  ; # JB5
set_property -dict { PACKAGE_PIN W16  IOSTANDARD LVCMOS33 } [get_ports { led[3] }]  ; # JB6
set_property -dict { PACKAGE_PIN V12  IOSTANDARD LVCMOS33 } [get_ports { led[4] }]  ; # JB7
set_property -dict { PACKAGE_PIN W13  IOSTANDARD LVCMOS33 } [get_ports { led[5] }]  ; # JB8

## Onboard physical LEDs (LD0-LD3) — TEMPORARY visual "is it alive" diagnostic
set_property -dict { PACKAGE_PIN R14  IOSTANDARD LVCMOS33 } [get_ports { onboard_led[0] }]
set_property -dict { PACKAGE_PIN P14  IOSTANDARD LVCMOS33 } [get_ports { onboard_led[1] }]
set_property -dict { PACKAGE_PIN N16  IOSTANDARD LVCMOS33 } [get_ports { onboard_led[2] }]
set_property -dict { PACKAGE_PIN M14  IOSTANDARD LVCMOS33 } [get_ports { onboard_led[3] }]

## Timing exceptions
set_false_path -to   [get_ports { led[*] }]
set_false_path -to   [get_ports { onboard_led[*] }]
