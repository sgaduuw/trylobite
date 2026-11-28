"""bin/ntpd sets the time of day from an NTP server. The tests need no
internet: tests/ntpsd.rs serves on the machine's own address over a loop
link, with a time a fixed offset from the machine's clock, and detrytus
--clock fixes that clock, so runs repeat exactly."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tests.test_clock import NOW

NTPSD = ROOT / "tests" / "ntpsd.rs"


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str, etc_init: str | None = None) -> str:
    """What the shell said to typed, the kernel's messages left out."""
    result = run_image(
        shell,
        input=typed,
        disk=bin_disk(programs=(NTPSD,), etc_init=etc_init),
        link="loop",
        clock=NOW,
        ram_pages=243,  # two Rust programs beside the shell's
        max_steps=200_000_000,
    )
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_ntpd_asks_and_only_init_s_programs_set_the_clock(shell):
    out = session(
        shell,
        "ntpsd 3600 | ntpd -n 10.0.0.2\n"
        "ntpsd 60 | ntpd -q 10.0.0.2\n"
        "ntpsd kiss | ntpd -n 10.0.0.2\n"
        "ntpd -q 10.0.0.2\n"
        "ntpd -x\n"
        "date +%T\n",
    )
    assert re.fullmatch(
        r"\$ ntpsd 3600 \| ntpd -n 10\.0\.0\.2\n"
        # Off by the server's hour, give or take half the way there and back.
        r"10\.0\.0\.2: offset \+3600\.0\d{5} s, delay \+0\.\d{6} s, stratum 2\n"
        # What the shell runs may ask, but not set the clock.
        r"\$ ntpsd 60 \| ntpd -q 10\.0\.0\.2\n"
        r"ntpd: setting the clock: not allowed\nsh: exit 1\n"
        r"\$ ntpsd kiss \| ntpd -n 10\.0\.0\.2\n"
        r"ntpd: 10\.0\.0\.2: the server sent a kiss of death\nsh: exit 1\n"
        r"\$ ntpd -q 10\.0\.0\.2\nntpd: 10\.0\.0\.2: no answer\nsh: exit 1\n"
        r"\$ ntpd -x\nusage: ntpd \[-n \| -q\] \[SERVER\]\nsh: exit 2\n"
        # So the clock is as it was, seconds after boot.
        r"\$ date \+%T\n01:30:\d\d\n"
        r"\$ \n",
        out,
    ), out


def test_ntpd_from_etc_init_sets_the_clock(shell):
    etc_init = "pipe\nnet\nip\n/bin/ntpsd 3600\n/bin/ntpd 10.0.0.2\n"
    out = session(shell, "sleep 5000000\ndate +%T\n", etc_init)
    assert re.search(
        r"ntpd: clock stepped by \+3600\.0\d{5} s \(10\.0\.0\.2\)\n", out
    ), out
    assert re.search(r"\$ date \+%T\n02:30:\d\d\n", out), out
