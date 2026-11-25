"""Programs in Rust (bin/*.rs), built by tools/fs.py with cargo and
`detrytus ll` (docs/rust.md), running in the shell."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str) -> str:
    result = run_image(shell, input=typed, disk=bin_disk(), max_steps=8_000_000)
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
