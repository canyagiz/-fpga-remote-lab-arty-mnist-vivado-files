# FPGA MNIST CNN Inference Lab — Project Brief for a Fresh Start

## Who you're helping

An intern at H-BRS building a remote-access FPGA lab experiment. The student
(end user of the finished lab) selects a handwritten digit image on a
website; that image is sent from a Raspberry Pi to the Arty board over a
UART cable, arriving directly in FPGA fabric (PL) — no ARM/PS involved in
the image path at all. The bitstream then runs real CNN inference on that
image, and the predicted digit is shown back to the student. This document
is a clean specification of what the finished system should do, written
after a previous long session got tangled in incremental fixes and lost
track of the overall picture. Start this implementation fresh — do not
assume any existing RTL/constraints file in this repo is correct; verify
everything from scratch.

## Hardware

- Board: Digilent **Arty Z7-20** (Xilinx Zynq-7000 XC7Z020).
- Toolchain: Xilinx **Vivado 2024.2**.
- The design must be **100% FPGA fabric (PL)** — no Zynq PS/ARM core
  involved anywhere, no AXI, no BOOT.BIN/FSBL. A prior version of this
  project routed images through the Zynq PS (UART → ARM firmware → shared
  BRAM); that entire approach has been abandoned in favor of receiving
  images directly in fabric. Do not reintroduce the PS.
- A Raspberry Pi is wired to the Arty board and is the sole interface
  between the lab's web backend and the FPGA: it drives buttons and reads
  LEDs, and will send image data to the FPGA over a serial (UART) line.

## What the FPGA must do

1. Receive a 28×28 grayscale image (784 bytes, one byte per pixel,
   row-major order: pixel[0][0], pixel[0][1], ..., pixel[0][27],
   pixel[1][0], ...) sent serially over UART from the Raspberry Pi directly
   into FPGA fabric (no ARM/PS in the path). 8N1 framing, agree on a baud
   rate with the Raspberry Pi side (suggest 115200).
2. On a button press (BTN1), run inference through this fixed CNN
   architecture (INT8 quantized weights, provided as `.mem` files for
   `$readmemh`):

   | Layer | Config | Output |
   |---|---|---|
   | Conv1 + ReLU | 8 filters, 3×3, valid | 26×26×8 |
   | MaxPool1 | 2×2, stride 2 | 13×13×8 |
   | Conv2 + ReLU | 16 filters, 3×3, valid | 11×11×16 |
   | MaxPool2 | 2×2, stride 2 | 5×5×16 |
   | FC1 + ReLU | 400→128 | 128 |
   | FC2 | 128→10 | 10 |
   | ArgMax | — | predicted digit 0–9 |

3. Output the result as a 4-bit binary value on LEDs (`led[3:0]`), plus
   `led[4]` = inference running, `led[5]` = result ready. The Raspberry Pi
   reads these LEDs over GPIO and relays the state to the lab website, which
   shows 4 equivalent virtual LEDs to the student. This LED-based readout is
   the actual, final result-display mechanism — not HDMI/video capture.

## Module naming (must match, this is what students see/write)

`top_module.v` (interface only, provided to students), `conv_module.v`,
`relu_module.v`, `maxpool_module.v`, `fc_module.v`, `argmax_module.v`
(students implement these five). A previous working implementation used a
serial "FETCH + MAC" (2 cycles per multiply-accumulate tap) FSM architecture
in each module — this is a reasonable reference approach but not mandatory;
any architecture that meets the fixed testbench's I/O contract is valid.

## Files already available (from `train.py`, do not need to be regenerated
unless something is actually wrong with them)

- `.mem` weight/bias files at INT8, FP32, INT4, INT2 precision, for all four
  weight-bearing layers (conv1, conv2, fc1, fc2) — for Lab 2's quantization
  comparison.
- `img_NNN_input.mem` (784 hex lines) + `labels.mem` — labeled test images
  for simulation, generated with a real seed each run.
- Calibration was done via a 1000-sample grid search to find per-layer
  requantization SHIFT values.

These live somewhere under this project directory (search for them — paths
may have drifted across the previous session's reorganizations). Verify
their contents are sane before trusting them blindly.

## Board I/O — pin mapping (hard-won lesson, verify before trusting any XDC in this repo)

The Arty Z7's **real Pmod JB header has exactly 8 signal pins** — confirmed
against Digilent's official `Arty-Z7-20-Master.xdc` (search Digilent's
`digilent-xdc` GitHub repo) and physically verified with a multimeter on
real hardware:

```
JB1=W14  JB2=Y14  JB3=T11  JB4=T10  JB5=V16  JB6=W16  JB7=V12  JB8=W13
```

(Pins 5/6/11/12 on the physical 12-pin connector are fixed GND/VCC, not
signals.) **Real Pmod JA** similarly has 8 signal pins:

```
JA1=Y18  JA2=Y19  JA3=Y16  JA4=Y17  JA5=U18  JA6=U19  JA7=W18  JA8=W19
```

A custom pin-reference document the user has (`XDC-DEFINITIONS-RPI-FPGA-
CONNECTIONS.txt` in their Downloads folder) uses **non-standard JA/JB
labels that do NOT match Digilent's real silkscreen** — e.g. it labels pins
on the real JB header as "JA3/JA4/JA7/JA8", and separately lists some LED
pins (W12, W11, V10, W8, W10) that turned out to be on the **ChipKit
header**, not JB, with W12 specifically being electrically unusable once
the Zynq PS's DDR/FIXED_IO interface occupies Bank 0 (irrelevant now that
PS is not used, but worth knowing W12 has other problems too). **Always
verify pin assignments against Digilent's real master XDC and a multimeter
on actual hardware — do not trust any custom pin-label document's naming at
face value; compare by package pin, not by label.**

Confirmed physical layout the user has already wired (verify still true,
things may have been rewired since):
- BTN0 (reset), BTN1 (start) on real JB3 (T11), JB4 (T10).
- LD0–LD5 on real JB1, JB2, JB5, JB6, JB7, JB8 (W14, Y14, V16, W16, V12,
  W13) — this was multimeter-verified as electrically correct and
  physically on the real JB connector in the previous session.
- Real Pmod JA is otherwise unused and available for the new UART RX line
  from the Raspberry Pi (JA1/Y18 was the previous plan, not yet physically
  wired or hardware-tested — confirm with the user).

## Clock

The board's onboard oscillator is 125 MHz on pin H16 (`IOSTANDARD LVCMOS33`,
single-ended — verified against Digilent's master XDC, not a differential
pair despite what some comments elsewhere may say).

**Important finding from the previous session**: a straightforward
serial "FETCH + MAC" datapath for this CNN, running directly at 125 MHz,
**failed timing closure** (worst observed combinational path ≈ 20.1 ns vs.
the 8 ns budget at 125 MHz — about 2.5× over budget). The fix used was a
Clocking Wizard (MMCM) dividing 125 MHz down to **40 MHz** for the whole
design (25 ns period, ~24% margin over the measured worst-case path). If
you rebuild the datapath significantly differently, re-measure timing
before assuming 40 MHz (or any other frequency) is correct — don't just
copy this number blindly.

If you do use a Clocking Wizard, be aware of two known Vivado 2024.2
quirks encountered previously (both cosmetic/methodology issues, not
functional problems, but worth handling cleanly from the start):
- It generates **two differently-named clock objects for the same physical
  output net** (e.g. `clk_out1_clk_wiz_0` and `clk_out1_clk_wiz_0_1`) —
  declare them related via `set_clock_groups -logically_exclusive` (they
  are the same signal, not actually asynchronous to each other) rather than
  trying to eliminate the duplicate.
- Any real clock-domain-crossing signal (there shouldn't be any once the PS
  is fully removed) needs a proper 2-FF synchronizer with `ASYNC_REG =
  "TRUE"` and an explicit `set_clock_groups -asynchronous` declaration.

## Simulation strategy

Full behavioral simulation of a real UART bit-bang transfer (784 bytes at
115200 baud ≈ 68 ms of simulated time) is impractically slow in xsim. The
previous session's approach: inject test images directly into the DUT's
internal image buffer via hierarchical reference from the testbench, and
force the "image ready" status signal, bypassing the real serial receiver
for simulation purposes only — this validates the CNN math datapath, not
the UART receiver itself (which can only be verified on real hardware).
This is a reasonable pattern to reuse, but implement and verify it
carefully — the previous session hit a real Verilog semantics bug here:
**`force`-ing a signal and then `release`-ing it snaps the signal back to
whatever its normal procedural logic last actually assigned**, not to
"whatever you want it to hold" — if the DUT's own always-block never
executes a real assignment to that signal during the forced window,
`release` can silently undo your intent. Test this bypass mechanism in
isolation before building a large test suite on top of it.

**Also verify, don't assume**: whatever internal clock the DUT's pipeline
actually runs on (e.g. an MMCM output) needs testbench wait-statements
timed to *that* clock, not the testbench's own input clock, once they
differ. Confirm signals are actually toggling by inspecting a live waveform
trace over time, not a single sampled value — the previous session wasted
significant time on a false alarm here (a signal that looked "stuck" in a
few point-in-time checks turned out to be toggling normally).

## Reference point: the CNN datapath itself is a solved problem

An earlier iteration of this project (before switching the image path to
direct UART-to-PL) had the exact same CNN math pipeline fully built,
timing-closed (WNS positive, 0 critical methodology warnings), bitstream-
generated, and **physically programmed and LED-pin-verified on real
hardware**. Only its image-loading mechanism (which went through the Zynq
PS at the time) differs from the current target architecture — the CNN
modules (`conv_module.v`, `relu_module.v`, `maxpool_module.v`,
`fc_module.v`, `argmax_module.v`) and their behavioral-simulation pass
results are architecture-agnostic with respect to how the image arrives.
This repo likely still contains that version's files — check before
rewriting the CNN math from scratch, since it's already verified working.
What needs fresh, careful work is specifically the UART-to-PL receiver and
its integration into `top_module.v`, since that's the part that hasn't been
gotten working yet.

## Suggested first steps for the new session

1. Inventory what's actually in this repo right now (RTL, constraints,
   Vivado project state) rather than trusting any prior description of it.
2. Reuse the already-verified CNN datapath modules as-is; focus new work on
   the UART receiver (`uart_rx_module.v` or equivalent) and its integration
   into `top_module.v` — that's the piece that needs to be built correctly
   this time.
3. Get the CNN datapath itself passing behavioral simulation first (with a
   simulation-only image-injection bypass, since full-speed UART simulation
   is impractically slow — see notes above), before debugging the real
   UART receiver's hardware timing.
4. Only after simulation passes, move to synthesis/timing closure, then
   real hardware bring-up (pin verification, bitstream programming, and
   finally an end-to-end test with the Raspberry Pi actually sending an
   image over the UART cable).
