# Engineering notes

## Design

### SUMP protocol subset

Implemented from sigrok's OLS driver source (`libsigrok/src/hardware/openbench-logic-sniffer`):

| Command | Bytes | Meaning |
|---|---|---|
| `0x00` | 1 | Reset: abort capture and readout. sigrok sends it 5× to resynchronize |
| `0x01` | 1 | Arm |
| `0x02` | 1 | ID: reply `1ALS` |
| `0x04` | 1 | Metadata: name, version, channels (16), memory (16,384 B), max rate, protocol 2 |
| `0x80` | 5 | Divider: rate = 100 MHz / (divider + 1) |
| `0x81` | 5 | Read count / 4 − 1 and delay (post-trigger) count / 4 − 1 |
| `0x82` | 5 | Flags: channel-group disable bits, internal test pattern |
| `0xC0` / `0xC1` | 5 | Trigger stage 0 mask / value |

Samples are returned **newest first**, one byte per enabled channel group, group 0 first. sigrok reverses them.

### Rate generator

SUMP rates are defined against a 100 MHz base clock. To support any system clock, the rate generator works in units where one clock = `RATE_P` and one sample period = `(divider+1) × RATE_Q`, with 100 MHz / f_clk = `RATE_P / RATE_Q` (25/3 at 12 MHz, 1/1 at 100 MHz).
- A counter `c` holds "units until the next sample, minus `RATE_P` + 1" as a signed number.
- Every clock it drops by `RATE_P`.
- When it goes negative (its sign bit, a plain flip-flop) a sample is taken and `(divider+1)·RATE_Q − RATE_P` is added back.

Average rates are exact. At 100 MHz every rate is exact.

### Memory

16 KB as two 8K × 8 simple dual-port block RAMs.
- **16 channels:** each sample writes both banks (8,192 samples).
- **8 channels:** samples alternate between banks (16,384 samples).

The metadata reports 16,384 bytes, and sigrok divides by the number of enabled groups, which gives exactly these limits.

### Pre-trigger correctness

After ARM, the trigger is not checked until `READ − DELAY` samples have been stored. Every sample sent back is therefore real data from this capture, never stale buffer contents. Test T7 covers it: a trigger condition that is already true at arm.

## Lessons from Lattice LSE

Three bugs passed simulation and failed on hardware. Each was found with a purpose-built debug bitstream: LED status maps, then a UART "status line" printer once the LEDs became untrustworthy.

1. **A home-made power-on reset was optimized away.** A counter that counts up and stops looks "stuck at 1" to LSE, so LSE replaced it with a constant (`stuck at One` warnings). *Fix:* no reset logic at all. Every register gets an initial value, which the MachXO3 loads at configuration.
2. **A `case` state machine locked up.** With its reset gone, the re-encoded FSM powered up in an illegal state and never left it. The UART saw every start bit but decoded nothing (`g0 f0` with the edge counter climbing). *Fix:* no encoded FSMs. Use plain counters and flags, where all-zeros means idle.
3. **A `case` lookup table became a ROM of zeros.** The board answered the ID query with `\0\0\0\0`, yet sent exactly 4 bytes, so the counter logic worked and only the data was lost. *Fix:* constant replies are loaded into shift registers. Registers loaded with constants can't be turned into a ROM.

## Timing closure at 100 MHz

The PLL's 100 MHz output needed a non-default configuration. With CLKOP feedback, 12 → 100 MHz needs an input divider of 3, which puts the PLL's phase-detector input below its minimum, so IPexpress refuses it. Feeding back from a 60 MHz CLKOS instead runs the VCO at 600 MHz.

The first 100 MHz build then missed timing badly. Each round below started from the worst path in the Place & Route Trace report:

| Round | Worst path | Fix | Result |
|---|---|---|---|
| 1 | Rate accumulator: add → subtract → two 28-bit compares in one clock; capture-size math with five chained ops | Pipeline configuration math (it only changes between captures); down-counter rate generator | 4,096 errors → **896**, worst −0.64 ns |
| 2 | `delay > read` clamp built by LSE as a **9-level LUT tree** (10.5 ns) | Rewrite magnitude compares as subtractions and use the borrow, which maps to the carry chain; power-of-two depth clamps become "any high bit set"; work in SUMP's 4-sample units | **61** errors, F<sub>max</sub> 95.9 MHz |
| 3 | Rate counter: borrow-compare chain then add chain, back to back (30 logic levels) | Offset the counter so "sample due" is its **sign bit**, leaving one add per clock | — |
| 3 | Test-signal generator: 24-bit compare driving the clock-enable of 168 flip-flops | Register the compare one clock early | **11** errors, F<sub>max</sub> 94.6 MHz |
| 4 | Block-RAM read (**4.7 ns** clock-to-out), then the 8:1 block select, then the byte select | Pipeline register after the block select. Readout is paced by the UART, so the extra clocks cost nothing | **0 errors at 100 MHz** |

Every change was re-verified against both testbenches. Sample timing and trigger positions stayed bit-identical through all rounds.
