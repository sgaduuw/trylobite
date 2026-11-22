"""The console server (user/consd.s): it drives the console, prints what
it is given, and keeps the foreground that Ctrl-C ends. Getc and Ctrl-C
themselves are in test_getc.py, test_waiting_getc.py and test_kill.py.
In these builds the console server is process 1, so init's children are
2 and up."""

from tests import kernel
from tests.kernel import GETC, exit_with, wait_for
from tests.test_files import report, said
from tests.test_wait import spin
from tools import fs

L = fs.L
CTRL_C = "\x03"
FOREVER = "1: j 1b"


def run(*args, **options):
    """kernel.run, with the console server built in and started first."""
    return kernel.run(*args, console=True, **options)


def write(label: str, n: int | str) -> str:
    return f"""
        CALL_CONSOLE
        li    a2, CN_WRITE
        la    a3, {label}
        li    a4, {n}
        sys"""


def foreground(register: str) -> str:
    return f"""
        CALL_CONSOLE
        li    a2, CN_FOREGROUND
        mv    a3, {register}
        sys"""


def test_write_prints_what_it_is_given_and_says_how_much():
    program = report(
        write("text", 6),  # "hello\n", not the rest
        write("long", 600),  # more than the server copies at a time
        write("text", 0),
        write("text", -1),
        "CALL_CONSOLE\n        li a2, CN_WRITE\n        li a3, 0\n"
        "        li a4, 3\n        sys",  # address 0: not the caller's
        data=f'text: .string "hello\\n, world"\nlong: .string "{"y" * 599}\\n"\n',
    )
    result = run(program)
    assert "hello\n" in result.console and ", world" not in result.console
    assert "y" * 599 + "\n" in result.console
    assert said(result) == [6, 600, 0, L["E_INVAL"], L["E_FAULT"]]


def test_foreground_takes_a_process_number_or_nobody():
    program = report(
        "li s1, NO_FOREGROUND\n" + foreground("s1"),
        "li s1, NPROC\n" + foreground("s1"),
        "li s1, -2\n" + foreground("s1"),
        "CALL_CONSOLE\n        li a2, CN_FOREGROUND + 1\n        sys",  # no such call
    )
    assert said(run(program)) == [0, L["E_INVAL"], L["E_INVAL"], L["E_INVAL"]]


def test_the_console_belongs_to_one_driver():
    # The console server drives it once it has registered, so init cannot.
    program = report(
        "li a0, SYS_LOOKUP\n        la a1, name\n        li a2, LOOKUP_WAIT\n"
        "        sys\n        li a0, 0",
        "li a0, SYS_DRIVE\n        li a1, SRC_CONSOLE\n        sys",
        data='name: .string "console"\n',
    )
    assert said(run(program)) == [0, L["E_BUSY"]]


def test_ctrl_c_for_a_process_that_is_not_the_namers_child_is_ordinary():
    # Init names itself, which is nobody's child: the kill fails, so the
    # Ctrl-C reaches a reader instead.
    init = f"""
        li    s1, 0
        {foreground("s1")}
        {GETC}
        {exit_with("a0")}
"""
    assert run(init, input=CTRL_C).code_of(0) == ord(CTRL_C)


def test_a_ctrl_c_that_ended_nothing_waits_for_the_next_foreground():
    # Program 1 ends at once, so init names a child that has ended: the
    # Ctrl-C typed ahead kills nothing (KILL_ENDED) and is kept. Program
    # 2, named next, never ends by itself: that Ctrl-C ends it.
    init = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        {spin(3000)}
        {foreground("s1")}
        li    a0, SYS_SPAWN
        li    a1, 2
        sys
        mv    s2, a0
        {foreground("s2")}
        {wait_for("s2")}
        mv    s3, a0
        {wait_for("s1")}
        {exit_with("s3")}
"""
    result = run(init, kernel.DONE, FOREVER, input=CTRL_C, harts=1)
    assert result.exit_code == 0, result.console
    assert result.code_of(0) == L["WAIT_KILLED"]


def test_kill_says_when_a_child_had_ended_already():
    init = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        {spin(3000)}
        li    a0, SYS_KILL
        mv    a1, s1
        li    a2, FOR_SELF
        sys
        mv    s2, a0
        {wait_for("s1")}
        {exit_with("s2")}
"""
    result = kernel.run(init, harts=1)
    assert result.code_of(0) == L["KILL_ENDED"]


def test_a_program_prints_through_the_console_server():
    # The shell's own programs do, as bin/hello does.
    init = f"""
        {write("msg", 3)}
        {exit_with("a0")}
msg:    .string "abc"
"""
    result = run(init)
    assert "abc" in result.console
    assert result.code_of(0) == 3
