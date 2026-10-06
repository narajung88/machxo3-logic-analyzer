#!/usr/bin/env python3
"""
sump.py -- command-line client for the MachXO3 logic analyzer (SUMP protocol).

PulseView/sigrok is the main front end; this tool is for bring-up, quick
checks and scripted captures. Needs `pip install pyserial`.

    python sump.py COM7 id                     # expect 1ALS
    python sump.py COM7 info                   # device metadata
    python sump.py COM7 selftest               # internal test pattern checks
    python sump.py COM7 capture --rate 1M --samples 8192 --vcd out.vcd
    python sump.py COM7 capture --rate 4M --samples 4096 --trigger 2=1 --pre 25 --vcd uart.vcd
    python sump.py COM7 capture --channels 8 --samples 16384 --rate 2M --vcd wide.vcd

Triggers: --trigger "CH=LEVEL,..." e.g. "0=1" (ch 0 high) or "3=0,4=1".
The capture is saved oldest-first; open the .vcd in PulseView or GTKWave.
"""

import argparse
import sys
import time

DEFAULT_BAUD = 921600
BASE_CLOCK = 100_000_000   # SUMP: rate = 100 MHz / (divider + 1)

F_NOISE = 0x0002
F_G0_OFF = 0x0004
F_G1_OFF = 0x0008
F_G23_OFF = 0x0030
F_TEST = 0x0800


def parse_rate(s: str) -> int:
    s = s.strip().lower().replace("hz", "")
    mult = 1
    if s.endswith("k"):
        mult, s = 1_000, s[:-1]
    elif s.endswith("m"):
        mult, s = 1_000_000, s[:-1]
    return int(float(s) * mult)


def parse_trigger(s: str):
    mask = value = 0
    if s:
        for part in s.split(","):
            ch, lvl = part.split("=")
            ch, lvl = int(ch), int(lvl)
            if not 0 <= ch <= 15 or lvl not in (0, 1):
                raise ValueError(f"bad trigger term '{part}'")
            mask |= 1 << ch
            value |= lvl << ch
    return mask, value


class Sump:
    def __init__(self, port, baud=DEFAULT_BAUD, timeout=0.5):
        import serial

        self.ser = serial.Serial(port, baud, timeout=timeout)
        time.sleep(0.05)
        self.reset()

    def close(self):
        self.ser.close()

    # -- low level -------------------------------------------------------------
    def reset(self):
        self.ser.write(b"\x00" * 5)
        time.sleep(0.01)
        self.ser.reset_input_buffer()

    def short(self, cmd):
        self.ser.write(bytes([cmd]))

    def long(self, cmd, value):
        self.ser.write(bytes([cmd]) + (value & 0xFFFFFFFF).to_bytes(4, "little"))

    # -- queries ---------------------------------------------------------------
    def id(self) -> bytes:
        self.reset()
        self.short(0x02)
        return self.ser.read(4)

    def metadata(self) -> dict:
        self.reset()
        self.short(0x04)
        meta = {}
        while True:
            k = self.ser.read(1)
            if not k or k[0] == 0:
                break
            key = k[0]
            if key >> 5 == 0:                      # string
                s = bytearray()
                while True:
                    c = self.ser.read(1)
                    if not c or c[0] == 0:
                        break
                    s += c
                meta[key] = s.decode(errors="replace")
            elif key >> 5 == 1:                    # u32 big-endian
                meta[key] = int.from_bytes(self.ser.read(4), "big")
            elif key >> 5 == 2:                    # u8
                meta[key] = self.ser.read(1)[0]
        return meta

    # -- capture ---------------------------------------------------------------
    def capture(self, rate=1_000_000, samples=4096, channels=16, mask=0, value=0,
                pre_percent=0, test_pattern=False, trigger_timeout=10.0, high_group=False):
        """Returns (samples_oldest_first, trigger_index or None, actual_rate)."""
        divider = max(0, BASE_CLOCK // rate - 1)
        actual_rate = BASE_CLOCK / (divider + 1)
        groups = 2 if channels == 16 else 1
        readcount = (samples + 3) // 4
        if mask:
            delaycount = max(1, int(readcount * (1 - pre_percent / 100.0)))
        else:
            delaycount = readcount
        flags = F_NOISE | F_G23_OFF
        if channels == 8:
            flags |= F_G0_OFF if high_group else F_G1_OFF
        if test_pattern:
            flags |= F_TEST

        self.reset()
        self.long(0xC0, mask)
        self.long(0xC1, value)
        self.long(0xC2, 0x08000000)                # stage 0, start
        self.long(0x80, divider)
        self.long(0x81, ((delaycount - 1) << 16) | (readcount - 1))
        self.long(0x82, flags)
        self.short(0x01)                           # ARM

        nbytes = readcount * 4 * groups
        data = bytearray()
        t0 = time.time()
        while len(data) < nbytes:
            chunk = self.ser.read(nbytes - len(data))
            if chunk:
                data += chunk
            elif not data and time.time() - t0 < trigger_timeout:
                continue                           # still waiting for the trigger
            else:
                break
        if len(data) < nbytes:
            self.reset()
            raise TimeoutError(f"got {len(data)} of {nbytes} bytes"
                               + (" (trigger never fired?)" if not data else ""))

        if groups == 2:
            vals = [data[2 * i] | (data[2 * i + 1] << 8) for i in range(nbytes // 2)]
        else:
            shift = 8 if high_group else 0
            vals = [b << shift for b in data]
        vals.reverse()                             # device sends newest first
        trig = (readcount - delaycount) * 4 if mask else None
        return vals, trig, actual_rate


def write_vcd(path, vals, rate, channels, trig=None, high_group=False):
    period_ns = 1e9 / rate
    ids = [chr(33 + i) for i in range(16)]
    used = range(16) if channels == 16 else (range(8, 16) if high_group else range(8))
    with open(path, "w") as f:
        f.write("$timescale 1 ns $end\n$scope module la $end\n")
        for ch in used:
            f.write(f"$var wire 1 {ids[ch]} ch{ch} $end\n")
        f.write("$upscope $end\n$enddefinitions $end\n")
        prev = None
        for i, v in enumerate(vals):
            if v != prev:
                f.write(f"#{round(i * period_ns)}\n")
                for ch in used:
                    bit = (v >> ch) & 1
                    if prev is None or bit != (prev >> ch) & 1:
                        f.write(f"{bit}{ids[ch]}\n")
                prev = v
        f.write(f"#{round(len(vals) * period_ns)}\n")
    if trig is not None:
        print(f"trigger at sample {trig} = {trig * period_ns / 1000:.2f} us")


# ------------------------------------------------------------------------------
def cmd_selftest(dev: Sump) -> bool:
    ok = True

    def check(cond, name):
        nonlocal ok
        print(f"{'PASS' if cond else 'FAIL'}  {name}")
        ok &= bool(cond)

    check(dev.id() == b"1ALS", "ID is 1ALS")
    meta = dev.metadata()
    check(meta.get(0x01) == "MachXO3 LA" and meta.get(0x20) == 16 and meta.get(0x21) == 16384,
          f"metadata: {meta.get(0x01)!r}, {meta.get(0x20)} ch, {meta.get(0x21)} B, "
          f"max {meta.get(0x23, 0) / 1e6:g} MHz")

    t = time.time()
    v, _, _ = dev.capture(rate=1_000_000, samples=8192, channels=16, test_pattern=True)
    dt = time.time() - t
    bad = sum(1 for a, b in zip(v, v[1:]) if (b - a) & 0xFFFF != 1)
    check(len(v) == 8192 and bad == 0, f"16 ch test pattern: 8192 samples in order ({dt:.2f} s)")

    v, _, _ = dev.capture(rate=1_000_000, samples=16384, channels=8, test_pattern=True)
    bad = sum(1 for a, b in zip(v, v[1:]) if (b - a) & 0xFF != 1)
    check(len(v) == 16384 and bad == 0, "8 ch test pattern: 16384 samples in order")

    for _ in range(3):
        v, _, _ = dev.capture(rate=2_000_000, samples=1024, test_pattern=True)
    check(len(v) == 1024, "repeated captures work")

    print()
    print("ALL TESTS PASSED" if ok else "SOME TESTS FAILED")
    return ok


def main():
    ap = argparse.ArgumentParser(description="MachXO3 logic analyzer client")
    ap.add_argument("port")
    ap.add_argument("--baud", type=int, default=DEFAULT_BAUD)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("id")
    sub.add_parser("info")
    sub.add_parser("selftest")
    c = sub.add_parser("capture")
    c.add_argument("--rate", default="1M", help="sample rate, e.g. 100k, 1M, 12M")
    c.add_argument("--samples", type=int, default=4096)
    c.add_argument("--channels", type=int, choices=[8, 16], default=16)
    c.add_argument("--high", action="store_true", help="with --channels 8: use channels 8-15")
    c.add_argument("--trigger", default="", help='e.g. "0=1" or "2=0,3=1"')
    c.add_argument("--pre", type=int, default=10, help="pre-trigger percent (with --trigger)")
    c.add_argument("--test", action="store_true", help="internal test pattern instead of probes")
    c.add_argument("--timeout", type=float, default=10.0, help="seconds to wait for the trigger")
    c.add_argument("--vcd", help="write the capture to this .vcd file")
    args = ap.parse_args()

    dev = Sump(args.port, args.baud)
    try:
        if args.cmd == "id":
            print(dev.id())
        elif args.cmd == "info":
            names = {0x01: "name", 0x02: "version", 0x20: "channels", 0x21: "memory (bytes)",
                     0x23: "max sample rate (Hz)", 0x24: "protocol"}
            for k, v in dev.metadata().items():
                print(f"{names.get(k, hex(k)):22s} {v}")
        elif args.cmd == "selftest":
            sys.exit(0 if cmd_selftest(dev) else 1)
        elif args.cmd == "capture":
            mask, value = parse_trigger(args.trigger)
            max_rate = dev.metadata().get(0x23, BASE_CLOCK)
            if BASE_CLOCK / (BASE_CLOCK // parse_rate(args.rate)) > max_rate:
                sys.exit(f"rate too high: this build samples at most {max_rate / 1e6:g} MHz")
            vals, trig, rate = dev.capture(parse_rate(args.rate), args.samples, args.channels,
                                           mask, value, args.pre, args.test, args.timeout,
                                           args.high)
            print(f"{len(vals)} samples at {rate / 1e6:g} MHz "
                  f"({len(vals) / rate * 1e3:.3f} ms)")
            if args.vcd:
                write_vcd(args.vcd, vals, rate, args.channels, trig, args.high)
                print(f"saved {args.vcd}")
            else:
                for i, v in enumerate(vals[:16]):
                    print(f"{i:5d}  {v:016b}")
                if len(vals) > 16:
                    print("  ... (use --vcd to save everything)")
    finally:
        dev.close()


if __name__ == "__main__":
    main()
