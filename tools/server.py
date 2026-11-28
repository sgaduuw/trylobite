#!/usr/bin/env python3
"""Build the Rust part of a server of the kernel image (docs/kernel.md).

    tools/server.py [-o FILE]    user/fsd-rust.s, from user/rust/fsd

cargo builds the crate, the crates it uses and core for detrytus's Rust
target, and `detrytus ll` translates their LLVM IR into assembly, only
the server's entry (fsd_main) and what it calls. user/fsd.s includes
the result in its program's section, after its start code and runtime.

A program of the image shares the build's one symbol table with the
kernel and every other program (AGENTS.md), and the kernel's Rust has
core's functions and runtime helpers of the same names: so every name
the translation defines, and the runtime functions it calls (memcpy and
the rest, which user/fsd.s provides), get the server's prefix, `fs$`.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tools.kernel import RUST_TARGET, BuildError, run  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CRATE = ROOT / "user" / "rust" / "fsd"
OUT = ROOT / "user" / "fsd-rust.s"
ENTRY = "fsd_main"
PREFIX = "fs$"
# What LLVM calls without the program asking: user/fsd.s has them, prefixed.
RUNTIME = {"abort", "memcpy", "memmove", "memset", "memcmp", "bcmp"}
CRATES = ("fsd", "tryfs", "core")

LABEL = re.compile(r"^([A-Za-z_$.][\w$.]*):", re.M)
NAME = re.compile(r"[A-Za-z_$.][\w$.]*")


def rust_ir() -> list[Path]:
    """The LLVM IR of the crate, of tryfs and of core."""
    cargo = shutil.which("cargo")
    if cargo is None:
        raise BuildError("no cargo to build the file server's Rust with")
    target = Path(tempfile.gettempdir()) / f"trylobite-fsd-{os.getuid()}"
    env = {
        **os.environ,
        "RUSTC_BOOTSTRAP": "1",
        "RUSTFLAGS": "--emit=llvm-ir,link -Zunstable-options -Cpanic=immediate-abort",
        "CARGO_TARGET_DIR": str(target),
    }
    args = ["--release", "--target", RUST_TARGET]
    # Cleaned first, so their IR is written afresh: a build cargo thinks
    # is up to date writes none.
    for crate in CRATES[:2]:
        run([cargo, "clean", "--quiet", "-p", crate, *args], cwd=CRATE, env=env)
    run([cargo, "build", "--quiet", "-Zbuild-std=core", *args], cwd=CRATE, env=env)
    deps = target / RUST_TARGET / "release" / "deps"
    found = []
    for crate in CRATES:
        ir = sorted(deps.glob(f"{crate}-*.ll"), key=lambda p: p.stat().st_mtime)
        if not ir:
            raise BuildError(f"cargo left no LLVM IR for {crate} in {deps}")
        found.append(ir[-1])
    return found


def prefixed(text: str) -> str:
    """The translation with every name it defines, and the runtime's,
    prefixed."""
    names = set(LABEL.findall(text)) | RUNTIME
    return NAME.sub(lambda m: PREFIX + m[0] if m[0] in names else m[0], text)


def build(out: Path = OUT) -> Path:
    binary = os.environ.get("DETRYTUS") or shutil.which("detrytus")
    if binary is None:
        raise BuildError(
            "no detrytus command: run tools/install-detrytus, or set DETRYTUS"
        )
    ir = rust_ir()
    with tempfile.TemporaryDirectory() as work:
        raw = Path(work) / "fsd.s"
        run([binary, "ll", "--root", ENTRY, *map(str, ir), "-o", str(raw)])
        out.write_text(prefixed(raw.read_text()))
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "-o", type=Path, default=OUT, help=f"where (default {OUT.relative_to(ROOT)})"
    )
    args = parser.parse_args()
    try:
        build(args.o)
    except BuildError as e:
        print(f"tools/server.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
