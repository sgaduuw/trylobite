"""The Rust toolchain the build pins, and cargo's environment for it.

rust-toolchain.toml names an exact release, so that every machine builds
the same Rust programs and kernel, and `make benchmark` counts the same
steps everywhere: another rustc means another LLVM, other code, and
another count. rustup reads the file in the repository (the kernel's
crate) and in each program's project, which gets a copy of it (fs.py),
and installs the release with rust-src and the target if it is missing.

rustc writes source paths into what it builds (where a panic would have
been), so a checkout or a rustup elsewhere would change the programs as
well: cargo_env() maps the repository to /trylobite and rust-src to
/rustc/COMMIT, as rustc's own standard library has it, so that no path
of the machine building them is left in them.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLCHAIN_FILE = ROOT / "rust-toolchain.toml"
TARGET = "riscv32imac-unknown-none-elf"
RUSTFLAGS = ["--emit=llvm-ir,link", "-Zunstable-options", "-Cpanic=immediate-abort"]


def pinned() -> str:
    """The release rust-toolchain.toml names, such as 1.100.1."""
    return tomllib.loads(TOOLCHAIN_FILE.read_text())["toolchain"]["channel"]


def rustc_info(cwd: Path) -> dict[str, str]:
    """`rustc -vV` as run in cwd, so with the toolchain rustup picks
    there: release, commit-hash and so on."""
    done = subprocess.run(
        ["rustc", "-vV"], cwd=cwd, capture_output=True, text=True, check=True
    )
    return dict(
        line.split(": ", 1) for line in done.stdout.splitlines() if ": " in line
    )


def check(info: dict[str, str]) -> None:
    """Warn once when the rustc in use is not the pinned one: a Rust
    without rustup ignores rust-toolchain.toml."""
    want, have = pinned(), info.get("release", "unknown")
    if have != want and not os.environ.get("_TRYLOBITE_RUSTC_WARNED"):
        os.environ["_TRYLOBITE_RUSTC_WARNED"] = "1"
        print(
            f"warning: rustc {have} is not the {want} rust-toolchain.toml pins:"
            " the Rust programs, and step counts, will differ from other machines",
            file=sys.stderr,
        )


def sysroot(cwd: Path) -> Path:
    done = subprocess.run(
        ["rustc", "--print", "sysroot"],
        cwd=cwd,
        capture_output=True,
        text=True,
        check=True,
    )
    return Path(done.stdout.strip())


def cargo_env(cwd: Path, target_dir: Path) -> tuple[dict[str, str], Path]:
    """The environment to run cargo in, in cwd, for detrytus' Rust
    target: build-std allowed, IR written, panics as traps, and the
    machine's paths mapped away (CARGO_ENCODED_RUSTFLAGS keeps a path
    with spaces in it whole); and the target directory it builds in,
    one under target_dir for each release, so that IR another rustc left
    there is never taken for this one's."""
    info = rustc_info(cwd)
    check(info)
    commit = info.get("commit-hash", "unknown")
    if not re.fullmatch(r"[0-9a-f]+", commit):
        commit = info.get("release", "unknown")
    src = sysroot(cwd) / "lib" / "rustlib" / "src" / "rust"
    flags = [
        *RUSTFLAGS,
        f"--remap-path-prefix={src}=/rustc/{commit}",
        f"--remap-path-prefix={ROOT}=/trylobite",
    ]
    target = target_dir / f"{info.get('release', 'unknown')}-{commit[:9]}"
    env = {
        **os.environ,
        "RUSTC_BOOTSTRAP": "1",
        "CARGO_ENCODED_RUSTFLAGS": "\x1f".join(flags),
        "CARGO_TARGET_DIR": str(target),
    }
    env.pop("RUSTFLAGS", None)
    return env, target
