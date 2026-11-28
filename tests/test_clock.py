"""Wall-clock time: SYS_CLOCK reads the machine's real-time clock, trystd's
time module turns it into SystemTime and a calendar, and bin/date prints
it. detrytus --clock fixes the clock so that runs repeat exactly."""

import re
import time

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run, run_image
from tests.test_files import report, said

# 2026-11-28 01:30:00 UTC, a Saturday.
NOW = 1795829400

# clock(): print the seconds, then the microseconds.
CLOCK = report(
    """
        li    a0, SYS_CLOCK
        sys
        mv    s0, a1""",
    "        mv    a0, s0",
)


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str, clock: int | None = NOW) -> str:
    """What the shell said to typed, the kernel's messages left out."""
    result = run_image(
        shell, input=typed, disk=bin_disk(), clock=clock, max_steps=60_000_000
    )
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_the_clock_call_gives_seconds_and_microseconds():
    seconds, micros = said(run(CLOCK, clock=NOW))
    assert 0 <= micros < 1_000_000
    # The clock started at NOW and moved a microsecond a tick since boot.
    ticks = (seconds - NOW) * 1_000_000 + micros
    assert 0 < ticks < 2_000_000


def test_without_a_fixed_clock_it_is_the_hosts():
    before = int(time.time())
    seconds, _ = said(run(CLOCK))
    assert before <= seconds <= time.time()


def test_date_prints_the_time_of_day(shell):
    assert session(shell, "date\n") == "$ date\nSat Nov 28 01:30:00 UTC 2026\n$ \n"


def test_date_formats_and_other_moments(shell):
    typed = (
        "date +%F_%T_%s\n"
        "date -d @0\n"
        "date -u -d @951782400 '+%a %j %e %y %%'\n"  # 2000-02-29, a leap day
        "date -d @-1 +%F_%T\n"
        "date -d @4102444800 +%F_%a\n"  # past 2^32 seconds and 2038
        "date -d @68719476736 +%F\n"
        "date -x\n"
    )
    assert session(shell, typed) == (
        "$ date +%F_%T_%s\n"
        "2026-11-28_01:30:00_1795829400\n"
        "$ date -d @0\n"
        "Thu Jan  1 00:00:00 UTC 1970\n"
        "$ date -u -d @951782400 '+%a %j %e %y %%'\n"
        "Tue 060 29 00 %\n"
        "$ date -d @-1 +%F_%T\n"
        "1969-12-31_23:59:59\n"
        "$ date -d @4102444800 +%F_%a\n"
        "2100-01-01_Fri\n"
        "$ date -d @68719476736 +%F\n"
        "4147-08-20\n"
        "$ date -x\n"
        "usage: date [-u] [-d @SECONDS] [+FORMAT]\n"
        "sh: exit 2\n"
        "$ \n"
    )
