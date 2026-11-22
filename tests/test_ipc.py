"""Messages for servers (kernel/ipc.s): call, receive and reply, copyin
and copyout while a server holds a call, notices of processes that end,
and the several block windows a server keeps its blocks in."""

import re

from tests.kernel import EXIT, exit_with, new_disk, run, wait_for
from tests.test_files import PUTN, said

E_NOPROC, E_SELF, E_FAULT, E_INVAL = -2, -3, -12, -10  # include/layout.s


def spawn(program: int, into: str) -> str:
    return f"""
        li    a0, SYS_SPAWN
        li    a1, {program}
        sys
        mv    {into}, a0"""


def _load(word: int | str) -> str:
    """mv for a register, la for a label, li for a number."""
    if re.fullmatch(r"[ast]\d", str(word)):
        return "mv"
    return "la" if str(word).isidentifier() else "li"


def call(pid: str, *words: int | str) -> str:
    regs = "".join(
        f"\n        {_load(w)}    a{2 + i}, {w}" for i, w in enumerate(words)
    )
    return f"""
        li    a0, SYS_CALL
        mv    a1, {pid}{regs}
        sys"""


def printed(*registers: str) -> str:
    """Print each register, in order: putn clobbers a0, a1 and t0..t3."""
    saves = "".join(f"\n        mv    s{5 + i}, {r}" for i, r in enumerate(registers))
    prints = "".join(
        f"\n        mv    a0, s{5 + i}\n        call  putn"
        for i in range(len(registers))
    )
    return saves + prints


# A server that answers each call with (the caller, w1 + w2, w3 * w4, 99)
# and leaves notices aside.
ADDER = """
        .gp   USER_GP
1:      li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, 1b
        add   t1, a1, a2
        mul   t2, a3, a4
        mv    a1, a0
        mv    a2, a0
        mv    a3, t1
        mv    a4, t2
        li    a5, 99
        li    a0, SYS_REPLY
        sys
        j     1b
"""


def test_a_call_gets_its_reply():
    init = f"""
        .gp   USER_GP
        {spawn(1, "s1")}
        {call("s1", 1, 2, 3, 4)}
        {printed("a0", "a1", "a2", "a3")}
        li    a1, 0
        {EXIT}
{PUTN}
"""
    result = run(init, ADDER)
    assert said(result) == [0, 3, 12, 99]
    # The server, asleep in receive with nobody left, does not count as
    # stuck: the machine powers off as when every process has exited.
    assert "all processes exited" in result.console


def test_a_server_takes_calls_one_at_a_time_from_many():
    client = f"""
        .gp   USER_GP
        li    a0, SYS_GETPID
        sys
        mv    s2, a0
        li    s1, 1                    # the server
        li    s3, 20
1:      {call("s1", "s2", 1000, "s3", 1)}
        addi  s3, s3, -1
        bnez  s3, 1b
        {exit_with("a1")}                  # the last reply's w1 + w2: pid + 1000
"""
    init = f"""
        {spawn(1, "s1")}
        {spawn(2, "s2")}
        {spawn(2, "s3")}
        {wait_for("s2")}
        mv    s4, a1
        {wait_for("s3")}
        add   a1, a1, s4
        {EXIT}
"""
    result = run(init, ADDER, client, max_steps=5_000_000)
    assert result.code_of(0) == 1002 + 1003


def test_calls_and_replies_that_cannot_be_made():
    init = f"""
        .gp   USER_GP
        li    s1, 5
        {call("s1", 0)}
        call  putn
        li    s1, 0
        {call("s1", 0)}
        call  putn
        li    a0, SYS_REPLY
        li    a1, 0
        sys
        call  putn
        {spawn(1, "s1")}
        li    a0, SYS_REPLY            # it is not calling
        mv    a1, s1
        sys
        call  putn
        li    a0, SYS_COPYIN
        mv    a1, s1
        li    a2, V_USER
        li    a3, V_USER
        li    a4, 1
        sys
        call  putn
        li    a1, 0
        {EXIT}
{PUTN}
"""
    result = run(init, ADDER)
    assert said(result) == [E_NOPROC, E_SELF, E_NOPROC, E_NOPROC, E_NOPROC]


def test_a_server_copies_from_and_to_its_caller():
    # The caller names a string and a buffer; the server copies the string
    # in, makes it upper case, and copies it out to the buffer.
    server = """
        .gp   USER_GP
1:      li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, 1b
        mv    s1, a0                   # s1: the caller
        mv    s2, a2                   # s2: where the result goes
        mv    s3, a3                   # s3: how long it is
        li    a0, SYS_COPYIN
        mv    a2, a1
        la    a3, here
        mv    a1, s1
        mv    a4, s3
        sys
        la    t1, here
        mv    t2, s3
2:      lt    t0, 0(t1)
        li    t3, 'a'
        blt   t0, t3, 3f
        addi  t0, t0, 'A' - 'a'
        st    t0, 0(t1)
3:      addi  t1, t1, 1
        addi  t2, t2, -1
        bnez  t2, 2b
        li    a0, SYS_COPYOUT
        mv    a1, s1
        la    a2, here
        mv    a3, s2
        mv    a4, s3
        sys
        mv    a2, a0                   # the reply: copyout's result
        mv    a1, s1
        li    a0, SYS_REPLY
        sys
        j     1b
here:   .zero 40
"""
    init = f"""
        .gp   USER_GP
        {spawn(1, "s1")}
        {call("s1", "text", "out", 14)}
        mv    a1, a0
        li    a0, 0
        bnez  a1, 9f
        li    a0, SYS_PUTS
        la    a1, out
        sys
9:      {exit_with("a0")}
text:   .string "shout, please\\n"
out:    .zero 20
"""
    result = run(init, server)
    assert "SHOUT, PLEASE\n" in result.console
    assert result.code_of(0) == 0


def test_a_copy_outside_either_process_copies_nothing():
    # Each call asks for a copy that runs past the caller's page by one
    # tryte; it has no block window there, so nothing is copied at all.
    server = """
        .gp   USER_GP
1:      li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, 1b
        mv    s1, a0
        mv    t4, a1                   # 0: copyout, 1: copyin, 2: n < 0
        li    a0, SYS_COPYOUT
        li    a4, 3
        bnez  t4, 2f
        mv    a1, s1
        la    a2, here
        li    a3, V_USER + 9840        # its last tryte but one, and past it
        li    a4, 3
        sys
        j     8f
2:      li    a0, SYS_COPYIN
        mv    a1, s1
        li    a2, V_USER + 9840
        la    a3, here
        li    t0, 2
        beq   t4, t0, 3f
        sys
        j     8f
3:      li    a4, -1
        sys
8:      mv    a2, a0
        mv    a1, s1
        li    a0, SYS_REPLY
        sys
        j     1b
here:   .tryte 'a', 'b', 'c'
"""
    init = f"""
        .gp   USER_GP
        {spawn(1, "s1")}
        {call("s1", 0)}
        call  putn
        {call("s1", 1)}
        call  putn
        {call("s1", 2)}
        call  putn
        li    t0, V_USER + 9840
        lt    a0, 0(t0)                # still 0
        call  putn
        li    a1, 0
        {EXIT}
{PUTN}
"""
    assert said(run(init, server)) == [E_FAULT, E_FAULT, E_FAULT, 0]


def test_a_receiver_hears_of_each_process_that_ends():
    # The server waits for a notice and exits with the number it names.
    server = f"""
1:      li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        bne   a0, t0, 1b
        li    t0, NOTE_ENDED
        bne   a1, t0, 1b
        {exit_with("a2")}
"""
    init = f"""
        {spawn(1, "s1")}
        li    a0, SYS_YIELD            # let it reach receive first
        sys
        {spawn(2, "s2")}
        {wait_for("s1")}
        sub   a1, a1, s2               # 0 when it named the client
        {EXIT}
"""
    result = run(init, server)
    assert result.code_of(0) == 0


def test_a_call_fails_when_its_server_ends():
    # This server takes a call and exits without replying.
    server = f"""
        li    a0, SYS_RECEIVE
        sys
        li    a1, 7
        {EXIT}
"""
    init = f"""
        {spawn(1, "s1")}
        {call("s1", 1)}
        {exit_with("a0")}
"""
    result = run(init, server)
    assert result.code_of(0) == E_NOPROC


def test_a_killed_caller_cannot_be_replied_to():
    # The server takes the call, init kills the caller, and the reply
    # finds nobody waiting.
    server = """
        li    a0, SYS_RECEIVE
        sys
        mv    s1, a0
        li    a0, SYS_SEND             # tell init it holds the call
        li    a1, 0
        li    a2, 1
        sys
        li    a0, SYS_RECV             # wait until init has killed it
        sys
        li    a0, SYS_REPLY
        mv    a1, s1
        sys
        mv    a1, a0
        li    a0, SYS_EXIT
        sys
"""
    client = f"""
        li    s1, 1
        {call("s1", 1)}
        {exit_with("a0")}
"""
    init = f"""
        {spawn(1, "s1")}
        {spawn(2, "s2")}
        li    a0, SYS_RECV
        sys
        li    a0, SYS_KILL
        mv    a1, s2
        li    a2, FOR_SELF
        sys
        {wait_for("s2")}
        mv    s3, a0                   # WAIT_KILLED
        li    a0, SYS_SEND
        mv    a1, s1
        li    a2, 1
        sys
        {wait_for("s1")}
        li    t0, 10
        mul   a1, a1, t0
        add   a1, a1, s3
        {EXIT}
"""
    result = run(init, server, client)
    assert result.code_of(0) == E_NOPROC * 10 + 2


def window(k: int | str) -> str:
    return f"li a0, SYS_WINDOW\n        li a1, {k}\n        sys"


def disk_call(op: str, block: int, buffer: str) -> str:
    """A call to the disk server: op on block, through buffer."""
    return f"""
        CALL_DISK
        li    a2, {op}
        li    a3, {block}
        li    a4, {buffer}
        sys"""


def test_block_windows_hold_a_block_each():
    # Windows 0 and 2 made, blocks 1 and 2 read into them, block 1 written
    # back from window 2; then window 9, which there cannot be, and a
    # read into window 1, which there is not.
    program = f"""
        .gp   USER_GP
        {window(0)}
        {window(2)}
        {disk_call("DK_READ", 1, "V_BLOCK")}
        li    t0, V_BLOCK
        li    t1, 11
        sw    t1, 0(t0)
        {disk_call("DK_READ", 2, "V_BLOCK + 2 * PAGE")}
        li    t0, V_BLOCK + 2 * PAGE
        li    t1, 22
        sw    t1, 0(t0)
        {disk_call("DK_WRITE", 1, "V_BLOCK + 2 * PAGE")}
        {disk_call("DK_READ", 1, "V_BLOCK")}
        li    t0, V_BLOCK              # block 1 again: now 22
        lw    a0, 0(t0)
        call  putn
        {window("NWIN")}
        call  putn
        {disk_call("DK_READ", 1, "V_BLOCK + PAGE")}
        call  putn
        li    a0, SYS_PUTS             # the window between is not there
        li    a1, V_BLOCK + PAGE
        sys
        call  putn
        li    a1, 0
        {EXIT}
{PUTN}
"""
    result = run(program, disk=(new_disk(), 4), disk_server=True)
    assert said(result) == [22, E_INVAL, E_FAULT, -2]


def test_block_windows_are_freed_with_their_process():
    # Each child takes every window, 13 pages with its own four; with 35
    # pages (30 after the disk server's 5) only one fits at a time, so the
    # second needs the first's back.
    child = """
        li    s1, NWIN
1:      addi  s1, s1, -1
        li    a0, SYS_WINDOW
        mv    a1, s1
        sys
        bnez  a0, 9f
        bnez  s1, 1b
9:      mv    a1, a0
        li    a0, SYS_EXIT
        sys
"""
    init = f"""
        li    s3, 3
1:      {spawn(1, "s1")}
        bltz  s1, 9f
        {wait_for("s1")}
        bnez  a1, 9f
        addi  s3, s3, -1
        bnez  s3, 1b
        li    s1, 0
9:      {exit_with("s1")}
"""
    result = run(init, child, ram_pages=35, disk_server=True)
    assert result.code_of(0) == 0
    assert [c for p, c in result.exits() if p != 0] == [0, 0, 0]
