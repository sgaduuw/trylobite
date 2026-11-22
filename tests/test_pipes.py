"""Pipes (user/piped.s): PP_PIPE gives a read end and a write end, as
descriptors; a read waits for something to read and gives 0 once no
write end is left, a write waits until all of it is in and fails with
E_PIPE once no read end is left. FD_NOINHERIT (kernel/desc.s) keeps a
descriptor out of children, as a shell keeps a pipe's other end."""

from tests import kernel
from tests.kernel import EXIT, wait_for
from tests.test_files import report, said
from tools import fs

L = fs.L

PIPE = "CALL_PIPE\n        li    a2, PP_PIPE\n        sys"


def run(*args, **options):
    """kernel.run, with the pipe server built in and started first."""
    return kernel.run(*args, pipes=True, **options)


def sys(call: str, *args: int | str) -> str:
    regs = "".join(f"\n        li    a{i}, {a}" for i, a in enumerate(args, 1))
    return f"\n        li    a0, {call}{regs}\n        sys"


def io(call: str, fd: int, label: str, n: int) -> str:
    return f"""
        li    a0, {call}
        li    a1, {fd}
        la    a2, {label}
        li    a3, {n}
        sys"""


def test_what_goes_in_one_end_comes_out_the_other():
    program = report(
        PIPE,  # 0 the read end, 1 the write end
        io("SYS_WRITE", 1, "msg", 5),
        io("SYS_READ", 0, "buf", 3),  # what was asked for
        "lt a0, buf",
        io("SYS_READ", 0, "buf", 9),  # what is left
        "lt a0, buf + 1",
        io("SYS_WRITE", 1, "msg", 0),
        sys("SYS_CLOSE", 1),
        io("SYS_READ", 0, "buf", 9),  # no writer left: the end
        io("SYS_READ", 0, "buf", 9),
        data='msg: .string "abcde"\n',
    )
    assert said(run(program)) == [0, 5, 3, ord("a"), 2, ord("e"), 0, 0, 0, 0]


def test_the_wrong_end_and_a_reader_gone():
    program = report(
        PIPE,
        io("SYS_WRITE", 0, "buf", 1),  # the read end
        io("SYS_READ", 1, "buf", 1),  # the write end
        io("SYS_READ", 0, "buf", -1),
        sys("SYS_CLOSE", 0),
        io("SYS_WRITE", 1, "buf", 1),  # nobody can read it
    )
    assert said(run(program)) == [
        0,
        L["E_BADF"],
        L["E_BADF"],
        L["E_INVAL"],
        0,
        L["E_PIPE"],
    ]


def test_closed_pipes_are_free_again():
    # More pipes, one after another, than the server has.
    step = PIPE + sys("SYS_CLOSE", 0) + sys("SYS_CLOSE", 1) + "\n        mv a0, zero"
    program = report(*[step] * (L["NHANDLE"] // 2 + 2), PIPE)
    assert said(run(program)) == [0] * (L["NHANDLE"] // 2 + 2) + [0]


def test_a_pipe_carries_more_than_it_holds_between_two_processes():
    # The child, holding only the write end as standard output, writes
    # 2000 trytes in one go; init reads them, 100 at a time, and sums
    # them, until the end comes when the child exits.
    n = 2000
    child = f"""
        .gp   USER_GP
        la    t0, cdata
        li    t1, {n}
1:      li    t2, 7
        rem   t2, t1, t2
        st    t2, 0(t0)
        addi  t0, t0, 1
        addi  t1, t1, -1
        bnez  t1, 1b
        {io("SYS_WRITE", "STDOUT", "cdata", n)}
        mv    a1, a0
        {EXIT}
cdata:  .zero {n}
"""
    init = f"""
        .gp   USER_GP
        {PIPE}                         # 0 the read end, 1 the write end:
        li    s0, 0                    # s0: the read end
        li    a0, SYS_FDFLAGS          # not for the child, whose standard
        li    a1, 0                    # output, 1, is the write end
        li    a2, FD_NOINHERIT
        sys
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s2, a0                   # s2: the child
        li    a0, SYS_CLOSE            # its only writer is the child
        li    a1, STDOUT
        sys
        li    s3, 0                    # s3: the sum
        li    s4, 0                    # s4: how many
1:      li    a0, SYS_READ
        mv    a1, s0
        la    a2, buf
        li    a3, 100
        sys
        blez  a0, 3f
        add   s4, s4, a0
        la    t0, buf
        add   t1, t0, a0
2:      lt    t2, 0(t0)
        add   s3, s3, t2
        addi  t0, t0, 1
        blt   t0, t1, 2b
        j     1b
3:      {wait_for("s2")}
        mv    a1, s4                   # the count
        li    t0, 100000
        mul   a1, a1, t0
        add   a1, a1, s3               # and the sum
        {EXIT}
buf:    .zero 100
"""
    result = run(init, child)
    total = sum(i % 7 for i in range(1, n + 1))
    assert result.code_of(2) == n  # all of it, in one write
    assert result.code_of(0) == n * 100000 + total


def test_a_child_does_not_inherit_what_is_marked_and_dup2_unmarks():
    child = f"""
        .gp   USER_GP
        {io("SYS_WRITE", 3, "cmsg", 1)}
        mv    s1, a0
        {io("SYS_WRITE", 4, "cmsg", 1)}
        li    t0, 100
        mul   a1, s1, t0
        add   a1, a1, a0
        {EXIT}
cmsg:   .string "x"
"""
    init = report(
        PIPE,  # 0 and 1
        sys("SYS_DUP2", 1, 3),
        sys("SYS_DUP2", 1, 4),
        sys("SYS_FDFLAGS", 3, "FD_NOINHERIT"),
        sys("SYS_FDFLAGS", 4, 2),  # no such flag
        sys("SYS_FDFLAGS", 5, 0),  # nothing there
        sys("SYS_DUP2", 3, 5),  # the copy is inherited
        sys("SYS_FDFLAGS", 5, 0),
        "li a0, SYS_SPAWN\n        li a1, 1\n        sys\n        mv s1, a0\n"
        f"        {wait_for('s1')}\n        mv a0, a1",
    )
    assert said(run(init, child)) == [
        0,
        3,
        4,
        0,
        L["E_INVAL"],
        L["E_BADF"],
        5,
        0,
        100 * L["E_BADF"] + 1,
    ]
