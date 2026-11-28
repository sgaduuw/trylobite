#!/usr/bin/env python3
"""Build the Rust part of the kernel (docs/kernel.md, "Rust in the kernel").

    tools/kernel.py [-o FILE]    kernel/trykern.s, from kernel/rust/trykern

cargo builds the crate and core for detrytus's Rust target, and `detrytus
ll` (with $DETRYTUS, or detrytus on the PATH) translates their LLVM IR
into assembly that include/kernel.s includes: its code in the kernel's
section, its data in the kernel's data section, its pointers signed so
that it reaches the kernel's addresses below 0, and only the functions
named rk_* and what they call (detrytus docs/rust.md). Building needs a
Rust toolchain with rust-src and the riscv32imac-unknown-none-elf target.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from tools import toolchain
except ImportError:  # run as a script: tools/ is on the path, not the repository
    import toolchain  # type: ignore[no-redef]

ROOT = Path(__file__).resolve().parent.parent
CRATE = ROOT / "kernel" / "rust" / "trykern"
OUT = ROOT / "kernel" / "trykern.s"
RUST_TARGET = "riscv32imac-unknown-none-elf"
SECTIONS = "kernel,kdata"  # include/kernel.s and kernel/data.s place them


class BuildError(Exception):
    pass


def run(command: list[str], **kwargs) -> None:
    done = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if done.returncode != 0:
        raise BuildError(done.stderr.strip() or done.stdout.strip())


def rust_ir() -> list[Path]:
    """The LLVM IR of the crate and of core, the crate's first."""
    cargo = shutil.which("cargo")
    if cargo is None:
        raise BuildError("no cargo to build the kernel's Rust with")
    work = Path(tempfile.gettempdir()) / f"trylobite-kernel-{os.getuid()}"
    env, target = toolchain.cargo_env(CRATE, work)
    args = ["--release", "--target", RUST_TARGET]
    # Cleaned first, so its IR is written afresh: a build cargo thinks is
    # up to date writes none.
    run([cargo, "clean", "--quiet", "-p", "trykern", *args], cwd=CRATE, env=env)
    run(
        [cargo, "build", "--quiet", "-Zbuild-std=core", *args],
        cwd=CRATE,
        env=env,
    )
    release = target / RUST_TARGET / "release"

    def newest(pattern: str) -> list[Path]:
        return sorted(release.rglob(pattern), key=lambda p: p.stat().st_mtime)

    crate, core = newest("trykern-*.ll"), newest("core-*.ll")
    if not crate or not core:
        raise BuildError(f"cargo left no LLVM IR for trykern in {release}")
    return [crate[-1], core[-1]]


def roots(ir: Path) -> list[str]:
    """The functions the assembly calls: every rk_* the crate defines."""
    return sorted(set(re.findall(r"^define [^@]*@(rk_\w+)\(", ir.read_text(), re.M)))


def build(out: Path = OUT) -> Path:
    binary = os.environ.get("DETRYTUS") or shutil.which("detrytus")
    if binary is None:
        raise BuildError(
            "no detrytus command: run tools/install-detrytus, or set DETRYTUS"
        )
    ir = rust_ir()
    names = roots(ir[0])
    if not names:
        raise BuildError("trykern defines no rk_* function")
    command = [binary, "ll", "--signed-pointers", "--sections", SECTIONS]
    for name in names:
        command += ["--root", name]
    run([*command, *map(str, ir), "-o", str(out)])
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
        print(f"tools/kernel.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
