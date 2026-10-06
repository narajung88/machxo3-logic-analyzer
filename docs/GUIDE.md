# Build and usage guide

## Hardware

Board: **Lattice MachXO3 Starter Kit** (LCMXO3L-6900C or LCMXO3LF-6900C). Everything uses header **J4**, pins 9–40.

| J4 pins | Function |
|---|---|
| 11, 12 | **GND** |
| 13–20 | **Probes 0–7** (pin 13 = ch 0 … pin 20 = ch 7) |
| 21, 22 | **GND** |
| 23–30 | **Probes 8–15** (pin 23 = ch 8 … pin 30 = ch 15) |
| 31, 32 | **GND** |
| 33 | Test signal: 1 MHz square |
| 34 | Test signal: 100 kHz square |
| 35 | Test signal: UART 115200 8N1, `Hello from MachXO3!` every 10 ms |
| 36 | Test signal: 1 kHz PWM, duty cycle steps 0–100 % every 100 ms |
| 9, 10, 37–40 | unused |

| Signal | J4 pin | FPGA ball | | Signal | J4 pin | FPGA ball |
|---|---|---|---|---|---|---|
| ch 0 | 13 | L15 | | ch 8 | 23 | J16 |
| ch 1 | 14 | L16 | | ch 9 | 24 | H15 |
| ch 2 | 15 | K14 | | ch 10 | 25 | H16 |
| ch 3 | 16 | K16 | | ch 11 | 26 | G15 |
| ch 4 | 17 | K15 | | ch 12 | 27 | G16 |
| ch 5 | 18 | J14 | | ch 13 | 28 | F15 |
| ch 6 | 19 | H14 | | ch 14 | 29 | F16 |
| ch 7 | 20 | J15 | | ch 15 | 30 | E15 |
| test 1 MHz | 33 | E16 | | test UART | 35 | D16 |
| test 100 kHz | 34 | E14 | | test PWM | 36 | C15 |

**Inputs are 3.3 V only and not 5 V tolerant.** Use a level shifter or divider for 5 V signals, and connect the target's GND to a J4 GND pin. Unconnected probes are pulled low.

**LEDs:** D9 armed (waiting for trigger) · D8 capturing · D7 sending · D2 heartbeat · D3 PLL locked (100 MHz build).

### One-time board setup

The FPGA reaches the PC through channel B of the on-board FT2232H.

1. **Bridge R14 and R15**, the unpopulated 0 Ω positions that connect the FTDI's channel-B UART to FPGA balls A11/C11.
2. In Windows Device Manager → *USB Serial Converter **B*** → Properties → Advanced: tick **Load VCP**, then replug the board. Leave it **unticked on converter A**: channel A is the JTAG programmer, and a COM port there makes Diamond's programmer stall.
3. On channel B's COM port → Port Settings → Advanced: set **Latency Timer = 1 ms**.

## Building in Lattice Diamond

### 12 MHz build (no PLL)

1. New project: LCMXO3L-6900C (or -LF), CABGA256, speed 5, synthesis **Lattice LSE**.
2. Add every file in `rtl/` **except `la_top_100.v`**. Set **`la_top`** as the top-level unit.
3. Add `constraints/la.lpf` and *Set as Active Preference File*.
4. Build and program SRAM (Programmer → Static RAM Cell Mode → Fast Program).

To keep the design across power cycles, program the SPI flash instead. On an XO3L, never choose NVCM: it is one-time programmable.

### 100 MHz build (PLL)

1. **Generate the PLL** with IPexpress (*Module → Architecture Modules → PLL*), file/module name **`pll_100`**, Verilog:
   - CLKI **12 MHz**
   - **CLKOS 60 MHz** (tolerance 0) with **feedback from CLKOS**
   - **CLKOP 100 MHz** (tolerance 0)
   - **LOCK** output enabled

   With the default CLKOP feedback, 100 MHz from 12 MHz needs an input divider of 3, which puts the PLL's phase-detector input below its minimum, so IPexpress refuses it. Feeding back from a 60 MHz output instead runs the VCO at 600 MHz: 100 = 600 ÷ 6, and 60 = 600 ÷ 10 = 12 × 5.
2. Use `rtl/la_top_100.v` instead of `la_top.v`, with **`la_top_100`** as the top-level unit, and the same `.lpf`.
3. Build and confirm the Place & Route Trace report shows **0 timing errors**.

## First test, no wiring

```
pip install pyserial
python host/sump.py COM7 selftest
```

This checks the ID and metadata, then captures the internal test pattern in 16- and 8-channel mode and verifies every sample. It should end with `ALL TESTS PASSED`. `python host/sump.py COM7 info` shows the maximum sample rate: 12 MHz or 100 MHz depending on the build.

## PulseView

1. Install PulseView from [sigrok.org](https://sigrok.org/wiki/Downloads) and close anything else using the COM port.
2. *Connect to a Device*:
   - Driver: **Openbench Logic Sniffer & SUMP compatibles (ols)**
   - Serial port: channel B's COM port, baud **921600**
   - *Scan*: it should find **MachXO3 LA with 16 channels**
3. Choose the sample count and rate, then click *Run*.

### Demo: decode the UART test signal

1. Jumper **J4 pin 35 → pin 13** (test UART → channel 0). Optionally 33 → 14, 34 → 15, 36 → 16.
2. Disable channels D8–D15 (allows 16k samples), then set 16k samples at 2 MHz.
3. Trigger on **D0 = low**, with the capture ratio around 10 %.
4. *Run*, then *Add protocol decoder → UART*: RX = D0, 115200 baud, ASCII. The decoder shows `Hello from MachXO3!`.

### Notes

- **12 MHz build:** rates where 12 MHz ÷ rate is a whole number (4 MHz, 2 MHz, 1 MHz, 500 kHz, …) sample perfectly evenly. Other rates are exact on average, with up to 83 ns of jitter. On the 100 MHz build every rate is exact.
- **Not implemented:**
  - RLE (keep it **off**, or the data will be garbled)
  - external clock
  - external test pattern
  - channel swap
  - multi-stage triggers (single-stage high/low triggers work)

## Command-line client

```
python host/sump.py COM7 info
python host/sump.py COM7 capture --rate 10M --samples 8192 --vcd capture.vcd
python host/sump.py COM7 capture --rate 2M --samples 16384 --channels 8 --trigger 0=0 --pre 10 --vcd uart.vcd
```

`.vcd` files open in PulseView (*Import → Value Change Dump*) or GTKWave.

## Simulation

```
make test       # or: make sim / make sim100
```

Needs Icarus Verilog. `sim/pll_100_sim.v` is a simulation-only stand-in for the Diamond PLL; never add it to the Diamond project.
