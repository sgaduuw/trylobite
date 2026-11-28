"""Wall-clock time: SYS_CLOCK reads the machine's real-time clock, trystd's
time module turns it into SystemTime and a calendar, and bin/date prints
it. SYS_MONOTONIC reads the monotonic clock, for trystd's Instant.
detrytus --clock fixes both so that runs repeat exactly."""

import re
import time

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run, run_image
from tests.test_files import report, said

# 2026-11-28 01:30:00 UTC, a Saturday.
NOW = 1795829400

# clock(): print the seconds, then the microseconds.
CLOCK_STEPS = (
    """
        li    a0, SYS_CLOCK
        sys
        mv    s0, a1""",
    "        mv    a0, s0",
)
CLOCK = report(*CLOCK_STEPS)


# monotonic() twice, then the time CSR: seconds and nanoseconds each.
MONOTONIC = report(
    """
        li    a0, SYS_MONOTONIC
        sys
        mv    s0, a1""",
    "        mv    a0, s0",
    """
        li    a0, SYS_MONOTONIC
        sys
        mv    s0, a1""",
    "        mv    a0, s0",
    "        csrr  a0, time",
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


def test_the_monotonic_clock_counts_from_the_start_and_never_back():
    s1, n1, s2, n2, ticks = said(run(MONOTONIC, clock=NOW))
    assert 0 <= n1 < 1_000_000_000 and 0 <= n2 < 1_000_000_000
    # With a fixed clock it is the ticks, a microsecond each: not the
    # time of day.
    first, second = s1 * 10**9 + n1, s2 * 10**9 + n2
    assert 0 < first < second <= ticks * 1000


def test_without_a_fixed_clock_the_monotonic_clock_is_real_time():
    started = time.monotonic()
    s1, n1, s2, n2, _ = said(run(MONOTONIC))
    assert (s1, n1) <= (s2, n2)
    assert s2 <= time.monotonic() - started + 1


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
    first, rest = session(shell, typed).split("$ date -d @0\n", 1)
    # The clock runs on from NOW as the machine boots: a second may pass.
    assert re.fullmatch(
        r"\$ date \+%F_%T_%s\n2026-11-28_01:30:0([01])_179582940\1\n", first
    )
    assert rest == (
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


# --- setting the clock ----------------------------------------------------------

E_INVAL, E_PERM = -10, -21  # include/layout.s


def step(seconds: int, micros: int) -> str:
    return f"""
        li    a0, SYS_STEPCLOCK
        li    a1, {seconds}
        li    a2, {micros}
        sys"""


def spawn_wait(program: int) -> str:
    return f"""
        li    a0, SYS_SPAWN
        li    a1, {program}
        sys
        mv    a1, a0
        li    a0, SYS_WAIT
        sys
        li    a0, 0"""


def renamed(program: str, suffix: str) -> str:
    """A report program whose labels do not clash with another's in the
    same build."""
    return re.sub(
        r"\b(putn|digits|digits_end|statbuf|buf|buf_end)\b", rf"\1{suffix}", program
    )


def test_init_s_children_step_the_clock_and_the_rest_may_not():
    # Init (0) may not, having no parent; its child (program 1) may, and
    # every process then reads the moved clock; program 1's own child
    # (program 2) may not.
    init = renamed(report(step(1, 0), spawn_wait(1)), "_i")
    child = report(
        step(3600, 900_000),
        step(0, 200_000),  # microseconds carry into the seconds
        step(0, 1_000_000),
        step(1, -1),
        step(-1, 1),
        step(-2, -100_000),
        *CLOCK_STEPS,
        spawn_wait(2),
    )
    grandchild = renamed(report(step(1, 0), *CLOCK_STEPS), "_g")
    result = run(init, child, grandchild, clock=NOW)
    (
        init_r,
        ok1,
        ok2,
        big,
        mixed1,
        mixed2,
        back,
        secs,
        micros,
        denied,
        secs2,
        _micros2,
        _,
        _,
    ) = said(result)
    assert (init_r, ok1, ok2, big, mixed1, mixed2, back) == (
        E_PERM,
        0,
        0,
        E_INVAL,
        E_INVAL,
        E_INVAL,
        0,
    ), result.console
    assert denied == E_PERM
    # Moved by 3600.9 + 0.2 - 2.1 = 3599 seconds, a microsecond a tick
    # since boot besides.
    ticks = (secs - NOW - 3599) * 1_000_000 + micros
    assert 0 < ticks < 2_000_000, (secs, micros)
    assert 0 <= secs2 - secs <= 2
