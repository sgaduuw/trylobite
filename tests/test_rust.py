"""Programs in Rust (bin/*.rs), built by tools/fs.py with cargo and
`detrytus ll` (docs/rust.md), running in the shell."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, max_steps: int = 8_000_000) -> str:
    result = run_image(shell, input=typed, disk=bin_disk(), max_steps=max_steps)
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_hello_from_rust(shell):
    assert said(shell, "rhello\n") == (
        "$ rhello\nhello from Rust on a balanced-ternary machine\n$ \n"
    )


def test_echo_in_rust_says_its_arguments(shell):
    assert said(shell, "recho  one   two three \nrecho\nrecho a b | wc\n") == (
        "$ recho  one   two three \none two three\n$ recho\n\n"
        "$ recho a b | wc\n1 2 4\n$ \n"
    )


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
