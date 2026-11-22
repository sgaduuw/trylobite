"""getc waits for input while the console is open: console input wakes
the reader through the interrupt controller, and only a closed console
makes getc return GETC_NONE.

`run` closes the console behind its input, so these tests type into the
debugger, which keeps it open until eof. Each `step` is long enough for
the program to be waiting in getc before the next line is typed."""

import re

from tests.kernel import (
    EXIT,
    GETC,
    ROOT,
    SPAWN_BOTH,
    assemble_file,
    bin_disk,
    build,
    debug_session,
)

WAIT = "step 300000\n"

# Print every character read until getc says there is none, then exit
# with what it said.
ECHO = f"""
1:      {GETC}
        bltz  a0, 2f
        mv    a1, a0
        li    a0, SYS_PUTC
        sys
        j     1b
2:      mv    a1, a0
        {EXIT}
"""

# Read one character and exit with it.
ONE = f"""
        {GETC}
        mv    a1, a0
        {EXIT}
"""


def program_output(session: str) -> str:
    """The program's output alone: the debugger's own lines dropped."""
    return re.sub(r"=> -?\d+ <[^\n]*\n|stopped: [^\n]*\n", "", session)


def test_getc_waits_for_input_and_only_eof_ends_it():
    out = debug_session(
        build(ECHO, console=True),
        f"{WAIT}input ab\\n\n{WAIT}input c\n{WAIT}eof\ncontinue\n",
    )
    # Each piece of input came after a wait, and the reader was still there
    # to echo it: it never saw GETC_NONE until eof.
    steps = [m.start() for m in re.finditer(r"=> -?\d+ <", out)]
    assert len(steps) == 3, out
    # The echoed c starts a line; the debugger's own lines may hold a c too.
    echo_c = out.index("\nc", steps[1])
    assert steps[0] < out.index("ab\n") < steps[1] < echo_c < steps[2]
    assert out.index("exited with code -1") > steps[2]
    # Waiting is sleeping, not polling: no timer slices went by meanwhile.
    ticks = int(re.search(r"after (\d+) timer interrupts", out).group(1))
    assert ticks <= 3, out


def test_eof_wakes_a_waiting_reader_with_none():
    out = debug_session(build(ECHO, console=True), f"{WAIT}eof\ncontinue\n")
    waited = re.search(r"=> -?\d+ <", out).start()
    assert out.index("process 0 exited with code -1") > waited, out


def test_input_goes_to_every_waiting_reader_once():
    init = SPAWN_BOTH
    out = debug_session(
        build(init, ONE, ONE, console=True), f"{WAIT}input xy\ncontinue\n"
    )
    codes = sorted(
        int(c) for c in re.findall(r"process [23] exited with code (-?\d+)", out)
    )
    assert codes == [ord("x"), ord("y")], out


def test_a_reader_left_waiting_after_the_others_is_woken_by_eof():
    out = debug_session(
        build(SPAWN_BOTH, ONE, ONE, console=True),
        f"{WAIT}input z\n{WAIT}eof\ncontinue\n",
    )
    codes = sorted(
        int(c) for c in re.findall(r"process [23] exited with code (-?\d+)", out)
    )
    assert codes == [-1, ord("z")], out


def test_the_shell_waits_at_its_prompt_for_what_is_typed():
    shell = assemble_file(ROOT / "shell.s")
    out = program_output(
        debug_session(
            shell,
            f"{WAIT}input hello\\n\n{WAIT}input exit\\n\ncontinue\n",
            disk=bin_disk(),
        )
    )
    assert out.startswith(
        "trylobite: booting\n"
        "$ hello\n"
        "hello from a balanced-ternary machine\n"
        "trylobite: process 4 exited with code 0\n"
        "$ exit\n"
        "trylobite: process 0 exited with code 0\n"
    ), out


# Spin for a long time, then exit with 7: keeps a hart busy in user mode.
SPIN = f"""
        li    t0, 400000
1:      addi  t0, t0, -1
        bnez  t0, 1b
        li    a1, 7
        {EXIT}
"""


def test_input_wakes_a_reader_while_another_process_keeps_the_hart_busy():
    # On one hart the spinner is running when the input comes, so the
    # interrupt lands in user mode and the kernel serves it from there.
    out = debug_session(
        build(SPAWN_BOTH, ONE, SPIN, console=True), f"{WAIT}input q\n{WAIT}", harts=1
    )
    assert f"process 2 exited with code {ord('q')}" in out, out
    assert "process 3 exited" not in out, out  # it was still spinning
