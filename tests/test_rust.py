"""Programs in Rust (bin/*.rs), built by tools/fs.py with cargo and
`detrytus ll` (docs/rust.md), running in the shell."""

import re
import struct

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tools.fs import Filesystem


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, max_steps: int = 8_000_000) -> str:
    result = run_image(shell, input=typed, disk=bin_disk(), max_steps=max_steps)
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_factorials_in_rust_with_println(shell):
    out = said(shell, "rfact 5\nrfact\nrfact 35\n")
    assert out.startswith(
        "$ rfact 5\n"
        " 1! =                                       1\n"
        " 2! =                                       2\n"
        " 3! =                                       6\n"
        " 4! =                                      24\n"
        " 5! =                                     120\n"
        "$ rfact\n"
    )
    assert "20! =                     2432902008176640000\n" in out
    assert out.endswith(
        "$ rfact 35\nusage: rfact [N], N from 1 to 34\nsh: exit 1\n$ \n"
    )


def test_factorials_past_64_bits(shell):
    out = said(shell, "rfact 34\n")
    assert "21! =                    51090942171709440000\n" in out
    assert "34! = 295232799039604140847618609643520000000\n" in out


def test_mandelbrot_in_floating_point(shell):
    # As numpy's float32 works it out, operation for operation.
    picture = [
        "              ..................        ",
        "         .................:--+.......   ",
        "      .................::-@@@@::........",
        "    ...............::=@*@@@@@@@@=@+=....",
        "   ........:-::::::-+@@@@@@@@@@@@@@-:...",
        "  ........:-=@@@@@*@@@@@@@@@@@@@@@@*....",
        "  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%-:....",
    ]
    picture += picture[-2::-1]
    out = said(shell, "rmandel\n", max_steps=60_000_000)
    assert out == "$ rmandel\n" + "".join(f"{line}\n" for line in picture) + "$ \n"


def shortest(x: float, single: bool = False) -> str:
    """x as Rust's `{}` prints it: the shortest decimal that reads back as
    the same f64 (or f32), with no exponent and no `.0` on a whole one."""

    def back(s: str) -> float:
        return struct.unpack("f", struct.pack("f", float(s)))[0] if single else float(s)

    if single:
        x = struct.unpack("f", struct.pack("f", x))[0]  # r as f32
    for digits in range(1, 18):
        s = f"{x:.{digits}g}"
        if back(s) == x:
            break
    assert "e" not in s
    return s.removesuffix(".0")


def newton_sqrt(x: float) -> float:
    """bin/rsqrt.rs's square root, step for step: IEEE f64 is the same
    here and in the coprocessor."""
    r = x
    while (step := (r + x / r) / 2) < r:
        r = step
    return r


def test_floats_print_with_braces(shell):
    # Core's float formatting makes rsqrt a program of more than one block.
    lines = []
    for k in range(1, 100):
        r = newton_sqrt(float(k))
        lines.append(f"sqrt({k}) = {shortest(r)} ({shortest(r, single=True)})\n")
    out = said(shell, "rsqrt 99\nrsqrt\nrsqrt 100\n", max_steps=40_000_000)
    assert out == (
        "$ rsqrt 99\n"
        + "".join(lines)
        + "$ rsqrt\n"
        + "".join(lines[:10])
        + "$ rsqrt 100\nusage: rsqrt [N], N from 1 to 99\nsh: exit 1\n$ \n"
    )
    assert "sqrt(2) = 1.414213562373095 (1.4142135)\n" in out


def test_sort_in_rust_on_the_heap(shell):
    # Vec<u8>, Vec<String> and core's sort, with memory from brk
    # (trystd's heap). 600 lines take the heap past a page.
    fruit = "pear\napple\nfig\napple\n"
    words = [f"line {(k * 7919) % 1000}" for k in range(600)]
    on = bin_disk(90, fruit=fruit, many="".join(f"{w}\n" for w in words))
    result = run_image(
        shell,
        input="rsort < fruit\nrsort -r -u < fruit\nrsort -x\nrsort < many > sorted\n",
        disk=on,
        max_steps=200_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert out == (
        "$ rsort < fruit\napple\napple\nfig\npear\n"
        "$ rsort -r -u < fruit\npear\nfig\napple\n"
        "$ rsort -x\nusage: rsort [-r] [-u]\nsh: exit 1\n"
        "$ rsort < many > sorted\n$ \n"
    )
    assert Filesystem.load(on[0]).read("sorted") == "".join(
        f"{w}\n" for w in sorted(words)
    )
