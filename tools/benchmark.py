#!/usr/bin/env python3
"""Time the emulator on a fixed piece of work: three Rust programs in a
pipeline sorting 10,000 lines on the shell's disk.

    tools/benchmark.py DISK [detrytus run options ...]

DISK is a disk built by `make` (it is copied, not changed). The words
are the same every run (a fixed seed), so the step count is too: a
change to the emulator that changes it has changed what the machine
does, not just how fast. Extra options go to `detrytus run`, such as
--no-jit or --ram-pages N. DETRYTUS names the binary, else `detrytus`
on the PATH.
"""

from __future__ import annotations

import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINES = 10_000
COMMAND = "rsort < words | tee sorted | rsort -r -u | wc"


def words() -> str:
    rng = random.Random(1958)  # the year of the first Setun
    letters = "abcdefghijklmnopqrstuvwxyz"
    lines = (
        "".join(rng.choice(letters) for _ in range(rng.randint(3, 10)))
        for _ in range(LINES)
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    disk, options = Path(sys.argv[1]), sys.argv[2:]
    detrytus = os.environ.get("DETRYTUS") or shutil.which("detrytus")
    if not detrytus:
        print("benchmark: no detrytus: run tools/install-detrytus", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory() as tmp:
        image = Path(tmp, "bench.img")
        text, script = Path(tmp, "words"), Path(tmp, "in")
        shutil.copy(disk, image)
        text.write_text(words())
        subprocess.run([ROOT / "tools/fs.py", "put", image, text, "words"], check=True)
        script.write_text(f"{COMMAND}\nexit\n")
        argv = [detrytus, "run", str(ROOT / "shell.s"), "--disk", str(image)]
        argv += ["--input", str(script), "--stats", "--max-steps", "10000000000"]
        argv += ["--ram-pages", "6561", *options]
        start = time.perf_counter()
        done = subprocess.run(argv, capture_output=True, text=True)
        seconds = time.perf_counter() - start
    steps = re.search(r"detrytus: (\d+) steps", done.stderr)
    counts = re.search(r"^\s*(\d+)\s+(\d+)\s+(\d+)\s*$", done.stdout, re.M)
    if done.returncode != 0 or not steps or not counts:
        sys.stdout.write(done.stdout)
        sys.stderr.write(done.stderr)
        print("benchmark: the run did not finish as expected", file=sys.stderr)
        return 1
    n = int(steps.group(1))
    print(f"{COMMAND}  ->  wc: {counts.group(0).strip()}")
    rate = n / seconds / 1e6
    print(f"{n:,} steps in {seconds:.1f} s: {rate:.1f} million steps a second")
    return 0


if __name__ == "__main__":
    sys.exit(main())
