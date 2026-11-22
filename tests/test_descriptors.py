"""Descriptors (kernel/desc.s): read and write on a number become calls to
the server behind it, and children inherit them. Only a server puts one
in a table (give), for a process whose call it holds, and it hears when
the last descriptor naming a handle of its goes. The console server
gives CONSOLE_HANDLE at CN_OPEN; in these builds it is process 1."""

from tests import kernel
from tests.kernel import EXIT, exit_with, wait_for
from tests.test_files import report, said
from tools import fs

L = fs.L

# Open the console as descriptor 0, once its server is there, and make 1
# and 2 copies, as the shell does.
CONSOLE_FDS = """
        li    a0, SYS_LOOKUP
        la    a1, con_name
        li    a2, LOOKUP_WAIT
        sys
        mv    s8, a0                   # s8: the console server
        li    a0, SYS_CALL
        mv    a1, s8
        li    a2, CN_OPEN
        sys
        li    a0, SYS_DUP2
        li    a1, STDIN
        li    a2, STDOUT
        sys
        li    a0, SYS_DUP2
        li    a1, STDIN
        li    a2, STDERR
        sys
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


def sys(call: str, *args: int | str) -> str:
    regs = "".join(f"\n        li    a{i}, {a}" for i, a in enumerate(args, 1))
    return f"""
        li    a0, {call}{regs}
        sys"""


def test_a_process_starts_with_no_descriptors():
    program = report(
        write("STDOUT", "buf", 1),
        read("STDIN", "buf", 1),
        sys("SYS_CLOSE", 0),
        sys("SYS_CLOSE", -1),
        sys("SYS_CLOSE", "NDESC"),
        sys("SYS_DUP2", 0, 1),
        sys("SYS_IOCALL", 0, "IO_LSEEK", 0, 0),
        sys("SYS_IOCALL", 0, 0, 0, 0),  # not an IO_ operation
        sys("SYS_IOCALL", 0, "IO_FIRST - 1", 0, 0),
    )
    assert said(kernel.run(program)) == [
        L["E_BADF"],
        L["E_BADF"],
        L["E_BADF"],
        L["E_BADF"],
        L["E_BADF"],
        L["E_BADF"],
        L["E_BADF"],
        L["E_INVAL"],
        L["E_INVAL"],
    ]


def test_open_gives_the_lowest_free_and_dup2_copies():
    program = report(
        "li a0, SYS_LOOKUP\n        la a1, con_name\n        li a2, LOOKUP_WAIT\n"
        "        sys\n        mv s8, a0",
        "li a0, SYS_CALL\n        mv a1, s8\n        li a2, CN_OPEN\n        sys",
        "li a0, SYS_CALL\n        mv a1, s8\n        li a2, CN_OPEN\n        sys",
        sys("SYS_DUP2", 0, 5),
        sys("SYS_DUP2", 0, 0),  # onto itself: nothing changes
        sys("SYS_DUP2", 0, "NDESC"),
        sys("SYS_DUP2", 4, 0),  # 4 names nothing
        sys("SYS_CLOSE", 0),
        "li a0, SYS_CALL\n        mv a1, s8\n        li a2, CN_OPEN\n        sys",
        write(5, "msg", 3),
        data=CON_NAME + 'msg: .string "hi\\n"\n',
    )
    result = run(program)
    assert said(result)[1:] == [0, 1, 5, 0, L["E_BADF"], L["E_BADF"], 0, 0, 3]
    assert "hi\n" in result.console


def test_only_the_server_whose_call_it_is_can_give():
    program = report(
        sys("SYS_GIVE", 1, -1),
        sys("SYS_GIVE", 1, "NHANDLE"),
        sys("SYS_GIVE", 1, 0),  # process 1 is not waiting for init's reply
        sys("SYS_GIVE", 0, 0),
    )
    assert said(kernel.run(program)) == [
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_NOPROC"],
        L["E_NOPROC"],
    ]


def test_a_call_cannot_pretend_to_come_from_a_descriptor():
    # IO_ operations reach a server only from descriptors it gave, so
    # the handle in one is one it gave: SYS_CALL refuses them.
    program = report(
        "li a0, SYS_LOOKUP\n        la a1, con_name\n        li a2, LOOKUP_WAIT\n"
        "        sys\n        mv s8, a0",
        "li a0, SYS_CALL\n        mv a1, s8\n        li a2, IO_WRITE\n"
        "        li a3, CONSOLE_HANDLE\n        la a4, con_name\n"
        "        li a5, 3\n        sys",
        data=CON_NAME,
    )
    assert said(run(program))[1:] == [L["E_INVAL"]]


# A server, program 1: it gives handle 5 to its first caller, answers its
# second call with the operation it got, or ends with 999 if a notice came
# first; then ends with 100 * the next notice's kind + its handle.
GIVER = f"""
        li    a0, SYS_RECEIVE
        sys
        mv    s0, a0
        li    a0, SYS_GIVE
        mv    a1, s0
        li    a2, 5
        sys
        mv    a2, a0
        li    a0, SYS_REPLY
        mv    a1, s0
        sys
1:      li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        bne   a0, t0, 2f
        li    t0, NOTE_ENDED           # a client ending: not what it waits for
        beq   a1, t0, 1b
        li    t0, 100
        mul   a1, a1, t0
        add   a1, a1, a2
        bnez  s1, 3f
        li    a1, 999                  # a notice before the second call
3:      {EXIT}
2:      mv    a2, a1
        li    a0, SYS_REPLY
        mv    a1, s0
        sys
        li    s1, 1
        j     1b
"""


def call_giver(op: int) -> str:
    return f"""
        li    a0, SYS_CALL
        li    a1, 1
        li    a2, {op}
        sys"""


def test_the_server_hears_when_the_last_descriptor_for_a_handle_goes():
    init = report(
        sys("SYS_SPAWN", 1),
        call_giver(0),  # the server gives descriptor 0
        sys("SYS_DUP2", 0, 3),
        sys("SYS_CLOSE", 0),  # 3 still names the handle: no notice
        call_giver(7),
        sys("SYS_CLOSE", 3),
        "li s1, 1\n" + wait_for("s1") + "\n        mv a0, a1",
        write(3, "buf", 1),
    )
    assert said(kernel.run(init, GIVER)) == [
        1,
        0,
        3,
        0,
        7,
        0,
        100 * L["NOTE_CLOSED"] + 5,
        L["E_BADF"],
    ]


def test_a_handle_closes_when_its_holder_ends():
    # Program 2 takes the handle and ends with it: the server hears.
    client = f"""
        {call_giver(0)}
        {call_giver(7)}
        {EXIT}
"""
    init = report(
        sys("SYS_SPAWN", 1),
        sys("SYS_SPAWN", 2),
        "li s1, 1\n" + wait_for("s1") + "\n        mv a0, a1",
    )
    assert said(kernel.run(init, GIVER, client)) == [1, 2, 100 * L["NOTE_CLOSED"] + 5]


def test_a_server_that_ends_takes_its_handles_with_it():
    init = report(
        sys("SYS_SPAWN", 1),
        call_giver(0),
        call_giver(7),
        sys("SYS_KILL", 1, "FOR_SELF"),
        "li s1, 1\n" + wait_for("s1"),
        write(0, "buf", 1),  # not E_NOPROC: the descriptor is gone
        sys("SYS_CLOSE", 0),
    )
    assert said(kernel.run(init, GIVER)) == [
        1,
        0,
        7,
        0,
        L["WAIT_KILLED"],
        L["E_BADF"],
        L["E_BADF"],
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
        data=CON_NAME,
    )
    assert said(run(program, input="x")) == [
        0,
        L["E_INVAL"],
        L["E_FAULT"],
        1,
        ord("x"),
    ]


def test_children_inherit_descriptors_and_closing_one_is_the_holders_own():
    # Program 1, started after init points its descriptors at the console,
    # writes on standard output and then closes it; init's stays open.
    child = f"""
        {write("STDOUT", "cmsg", 6)}
        mv    s1, a0
        li    a0, SYS_CLOSE
        li    a1, STDOUT
        sys
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
