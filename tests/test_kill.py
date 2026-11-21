"""kill and Ctrl-C: ending a process that will not end by itself."""

import pytest

from tests.kernel import (
    EXIT,
    ROOT,
    assemble_file,
    bin_disk,
    exit_with,
    run,
    run_image,
    wait_for,
)
from tests.test_wait import spawn_and_wait, spin

E_NOCHILD = -2  # include/layout.s
WAIT_KILLED = 2
CTRL_C = "\x03"

FOREVER = "1: j 1b"  # never makes a system call: only the timer stops it

# Read code points until getc says there are none, then exit with 5: a
# reader that only a kill ends before the input does.
READER = f"""
1:      li    a0, SYS_GETC
        sys
        bgez  a0, 1b
        li    a1, 5
        {EXIT}
"""


def kill(register: str) -> str:
    return f"li a0, SYS_KILL\n        mv a1, {register}\n        sys"


def test_kill_ends_a_child_that_never_makes_a_system_call():
    # With more than one hart the spinner may be running elsewhere: it
    # goes at its next timer interrupt.
    result = run(
        spawn_and_wait(before_wait=spin(2000) + "\n        " + kill("s1")), FOREVER
    )
    assert result.exit_code == 0, result.console
    assert "process 1 killed" in result.console
    assert result.code_of(0) == 1000 * WAIT_KILLED + 0


def test_kill_ends_a_child_blocked_in_recv():
    # Nobody will ever send to it: only the kill wakes it.
    blocked = f"li a0, SYS_RECV\n        sys\n        {exit_with('a0')}"
    result = run(spawn_and_wait(before_wait=kill("s1")), blocked)
    assert result.exit_code == 0, result.console  # no deadlock
    assert result.code_of(0) == 1000 * WAIT_KILLED


def test_kill_and_foreground_refuse_a_process_that_is_not_a_child():
    for call in ("SYS_KILL", "SYS_FOREGROUND"):
        init = f"""
        li    a0, {call}
        li    a1, 0                    # itself
        sys
        {exit_with("a0")}
"""
        assert run(init).code_of(0) == E_NOCHILD


def foreground_and_wait() -> str:
    """Spawn program 1, give it the console, wait, and exit with
    1000 * how it ended + its code."""
    return f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        li    a0, SYS_FOREGROUND
        mv    a1, s1
        sys
        {wait_for("s1")}
        li    t0, 1000
        mul   a0, a0, t0
        add   a1, a0, a1
        {EXIT}
"""


def test_ctrl_c_kills_the_foreground_process():
    result = run(foreground_and_wait(), FOREVER, input=CTRL_C)
    assert result.exit_code == 0, result.console
    assert result.code_of(0) == 1000 * WAIT_KILLED


def test_ctrl_c_kills_a_foreground_process_reading_the_console():
    # It would read "ab" and then exit with 5 at the end of input; Ctrl-C
    # ends it first, and takes the code points typed before it along.
    result = run(foreground_and_wait(), READER, input="ab" + CTRL_C)
    assert result.code_of(0) == 1000 * WAIT_KILLED


def test_without_a_foreground_ctrl_c_is_an_ordinary_code_point():
    result = run(
        f"li a0, SYS_GETC\n        sys\n        {exit_with('a0')}", input=CTRL_C
    )
    assert result.code_of(0) == 3


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def test_ctrl_c_stops_a_runaway_program_and_the_shell_carries_on(shell):
    result = run_image(
        shell, input="spin\n" + CTRL_C + "hello\nexit\n", disk=bin_disk()
    )
    assert result.exit_code == 0, result.console
    lines = result.console.splitlines()
    i = lines.index("$ spin")
    assert lines[i + 1 : i + 5] == [
        "trylobite: process 1 killed",
        "sh: killed",
        "$ hello",  # typed after the Ctrl-C: kept
        "hello from a balanced-ternary machine",
    ]


def test_ctrl_c_at_the_prompt_drops_the_line(shell):
    result = run_image(shell, input="hel" + CTRL_C + "hello\nexit\n", disk=bin_disk())
    assert result.exit_code == 0, result.console
    assert "$ hel^C\n$ hello\nhello from" in result.console
