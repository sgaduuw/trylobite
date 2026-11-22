"""Descriptors (kernel/desc.s): read and write on a number become calls to
the server behind it, and children inherit them. The console server
answers on CONSOLE_HANDLE; in these builds it is process 1."""

from tests import kernel
from tests.kernel import EXIT, exit_with, wait_for
from tests.test_files import report, said
from tools import fs

L = fs.L

# Point descriptors 0 to 2 at the console, once its server is there.
CONSOLE_FDS = """
        li    a0, SYS_LOOKUP
        la    a1, con_name
        li    a2, LOOKUP_WAIT
        sys
        mv    s8, a0                   # s8: the console server
        li    s7, STDERR
9:      li    a0, SYS_DESC
        mv    a1, s7
        mv    a2, s8
        li    a3, CONSOLE_HANDLE
        sys
        addi  s7, s7, -1
        bgez  s7, 9b
"""
CON_NAME = 'con_name: .string "console"\n'


def run(*args, **options):
    """kernel.run, with the console server built in and started first."""
    return kernel.run(*args, console=True, **options)


def write(fd: int | str, label: str, n: int) -> str:
    return f"""
        li    a0, SYS_WRITE
        li    a1, {fd}
        la    a2, {label}
        li    a3, {n}
        sys"""


def read(fd: int | str, to: str, n: int) -> str:
    load = "la" if str(to).isidentifier() else "li"
    return f"""
        li    a0, SYS_READ
        li    a1, {fd}
        {load}    a2, {to}
        li    a3, {n}
        sys"""


def desc(fd: int | str, server: str, handle: int | str = "CONSOLE_HANDLE") -> str:
    return f"""
        li    a0, SYS_DESC
        li    a1, {fd}
        li    a2, {server}
        li    a3, {handle}
        sys"""


def test_a_process_starts_with_no_descriptors():
    program = report(
        write("STDOUT", "buf", 1),
        read("STDIN", "buf", 1),
        desc(-1, 1),
        desc("NDESC", 1),
        desc(3, -2),  # no process has that number
        desc(3, "NO_DESC"),  # closing one that names nothing is fine
    )
    assert said(kernel.run(program)) == [
        L["E_BADF"],
        L["E_BADF"],
        L["E_BADF"],
        L["E_BADF"],
        L["E_NOPROC"],
        0,
    ]


def test_write_on_standard_output_reaches_the_console():
    program = report(
        CONSOLE_FDS + write("STDOUT", "msg", 6),
        write("STDERR", "err", 4),
        data=CON_NAME + 'msg: .string "hello\\n"\nerr: .string "err\\n"\n',
    )
    result = run(program)
    assert "hello\n" in result.console and "err\n" in result.console
    assert said(result) == [6, 4]


def test_read_on_standard_input_gives_what_was_typed_then_0():
    # Echo standard input to standard output until read says 0, then exit
    # with how many code points came.
    init = f"""
        {CONSOLE_FDS}
        li    s0, 0
1:      {read("STDIN", "buf", 10)}
        blez  a0, 2f
        add   s0, s0, a0
        mv    a3, a0
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, buf
        sys
        j     1b
2:      {exit_with("s0")}
buf:    .zero 10
{CON_NAME}
"""
    result = run(init, input="balanced\nternary\n")
    assert "balanced\nternary\n" in result.console
    assert result.code_of(0) == len("balanced\nternary\n")


def test_what_a_console_read_refuses():
    program = report(
        CONSOLE_FDS + read("STDIN", "buf", 0),  # nothing asked: 0 at once
        read("STDIN", "buf", -1),
        read("STDIN", 0, 1),  # not its memory: the code point stays
        read("STDIN", "buf", 1),
        "lt a0, buf",
        "li a0, SYS_DESC\n        li a1, STDIN\n        mv a2, s8\n"
        "        li a3, 5\n        sys",
        read("STDIN", "buf", 1),  # a handle the console never gave
        data=CON_NAME,
    )
    assert said(run(program, input="x")) == [
        0,
        L["E_INVAL"],
        L["E_FAULT"],
        1,
        ord("x"),
        0,
        L["E_BADF"],
    ]


def test_children_inherit_descriptors_and_closing_one_is_the_holders_own():
    # Program 1, started after init points its descriptors at the console,
    # writes on standard output and then closes it; init's stays open.
    child = f"""
        {write("STDOUT", "cmsg", 6)}
        mv    s1, a0
        {desc("STDOUT", "NO_DESC")}
        {write("STDOUT", "cmsg", 6)}
        li    t0, 100
        mul   a1, s1, t0
        add   a1, a1, a0               # 100 * the first + the second
        {EXIT}
cmsg:   .string "child\\n"
"""
    init = f"""
        {CONSOLE_FDS}
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        {wait_for("s1")}
        mv    s2, a1
        {write("STDOUT", "imsg", 5)}
        li    t0, 100
        mul   a1, s2, t0
        add   a1, a1, a0
        {EXIT}
imsg:   .string "init\\n"
{CON_NAME}
"""
    result = run(init, child)
    assert "child\n" in result.console and "init\n" in result.console
    assert result.code_of(2) == 600 + L["E_BADF"]
    assert result.code_of(0) == (600 + L["E_BADF"]) * 100 + 5


def test_a_descriptor_naming_no_server_fails_its_calls():
    # The kernel checks only the number: the call finds nobody there.
    program = report(desc("STDOUT", 7), write("STDOUT", "buf", 1))
    assert said(kernel.run(program)) == [0, L["E_NOPROC"]]
