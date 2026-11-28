"""Threads: slots of the process table sharing one process's memory
(docs/kernel.md, Threads). thread starts one, thread_exit and join end
and collect one, futex lets them wait for each other, and exit, a fault
or a kill in any thread ends them all before the pages go back."""

from tests.kernel import (
    EXIT,
    LOAD_PAGE_FAULT,
    build,
    exit_with,
    run,
    run_image,
    wait_for,
)
from tests.test_wait import process_states

E_PERM, E_INVAL, E_NOCHILD, E_BUSY, E_AGAIN = -21, -10, -2, -19, -27  # include/layout.s
WAIT_EXITED, WAIT_FAULTED, WAIT_KILLED = 0, 1, 2

# A thread's stack, below the first thread's (which grows down from
# V_USER) in the lower half of the process's page, and a word both see.
STACK = "V_USER - 3000"
SHARED = "V_USER - 6000"


def thread(entry: str, arg: str = "li a3, 0", stack: str = STACK) -> str:
    """Start a thread at entry: its number in a0."""
    return f"""
        li    a0, SYS_THREAD
        la    a1, {entry}
        li    a2, {stack}
        {arg}
        li    a4, 0
        sys"""


def join(register: str, how: str = "JOIN_WAIT") -> str:
    return f"""li    a0, SYS_JOIN
        mv    a1, {register}
        li    a2, {how}
        sys"""


def texit(code: int) -> str:
    return f"li a0, SYS_TEXIT\n        li a1, {code}\n        sys"


def spin(rounds: int, label: int = 7) -> str:
    return f"""
        li    s0, 0
{label}:      addi  s0, s0, 1
        li    t0, {rounds}
        blt   s0, t0, {label}b"""


def spawn_and_wait(before_wait: str = "") -> str:
    """Init: spawn program 1, wait, exit with 1000 * how it ended + its
    code."""
    return f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        {before_wait}
        {wait_for("s1")}
        li    t0, 1000
        mul   a0, a0, t0
        add   a1, a0, a1
        {EXIT}
"""


def test_a_thread_runs_in_the_same_memory_and_join_gives_its_code():
    # The thread doubles its argument into the shared word and ends with
    # 7; the first thread joins it, then exits with what it finds there
    # plus 100 times the code.
    init = f"""
        {thread("worker", arg="li a3, 21")}
        mv    s1, a0
        {join("s1")}
        bnez  a0, 1f
        li    t0, 100
        mul   s2, a1, t0
        li    t0, {SHARED}
        lw    t1, 0(t0)
        add   s2, s2, t1
        {exit_with("s2")}
1:      {exit_with("a0")}
worker: add   a0, a0, a0
        li    t0, {SHARED}
        sw    a0, 0(t0)
        {texit(7)}
"""
    result = run(init)
    assert result.exit_code == 0, result.console
    assert result.code_of(0) == 742


def test_a_thread_has_its_own_number_and_its_processs():
    # gettid is the thread's slot, getpid its process's: 1000 * tid + pid.
    init = f"""
        {thread("worker")}
        mv    s1, a0
        {join("s1")}
        {exit_with("a1")}
worker: li    a0, SYS_GETTID
        sys
        li    t0, 1000
        mul   s0, a0, t0
        li    a0, SYS_GETPID
        sys
        add   a1, s0, a0
        li    a0, SYS_TEXIT
        sys
"""
    assert run(init).code_of(0) == 1000


def test_a_process_whose_threads_ended_frees_every_slot():
    # Two threads end alone, one joined and one not: once the process
    # exits, every record is free.
    init = f"""
        {thread("worker")}
        mv    s1, a0
        {thread("worker", stack="V_USER - 4500")}
        {join("s1")}
        {spin(3000)}
        li    a1, 0
        {EXIT}
worker: {texit(1)}
"""
    image = build(init)
    result = run_image(image)
    assert result.exit_code == 0, result.console
    assert process_states(result, image) == [0] * image.symbols["NPROC"]


def test_join_refuses_what_it_cannot_join():
    # Itself (E_INVAL), a slot that is not its thread (E_NOCHILD), a bad
    # how (E_INVAL), and a thread still running with JOIN_POLL (E_BUSY):
    # each result a digit of the exit code, in tens.
    init = f"""
        li    a0, SYS_GETTID
        sys
        mv    s1, a0
        {join("s1")}
        mv    s2, a0
        li    s1, 5
        {join("s1")}
        li    t0, 100
        mul   t0, a0, t0
        add   s2, s2, t0
        {thread("worker")}
        mv    s3, a0
        li    a0, SYS_JOIN
        mv    a1, s3
        li    a2, 5
        sys
        li    t0, 10000
        mul   t0, a0, t0
        add   s2, s2, t0
        {join("s3", "JOIN_POLL")}
        li    t0, 1000000
        mul   t0, a0, t0
        add   s2, s2, t0
        {exit_with("s2")}
worker: {spin(100000)}
        {texit(0)}
"""
    code = run(init).code_of(0)
    assert code == E_INVAL + 100 * E_NOCHILD + 10000 * E_INVAL + 1000000 * E_BUSY


def test_the_first_thread_cannot_end_alone():
    init = f"""
        {texit(3)}
        {exit_with("a0")}
"""
    assert run(init).code_of(0) == E_PERM


def test_futex_sleeps_until_woken_and_refuses_a_changed_word():
    # The worker sleeps on the shared word while it is 0. The first
    # thread first waits with the wrong value (E_AGAIN), lets the worker
    # get to sleep, sets the word, wakes it (one woken), and joins it.
    init = f"""
        li    t0, {SHARED}
        sw    zero, 0(t0)
        {thread("worker")}
        mv    s1, a0
        li    a0, SYS_FUTEX
        li    a1, {SHARED} - 1
        li    a2, FUTEX_WAIT
        li    a3, 1
        sys
        mv    s2, a0
        {spin(20000)}
        li    t0, {SHARED}
        li    t1, 1
        sw    t1, 0(t0)
        li    a0, SYS_FUTEX
        li    a1, {SHARED} - 1
        li    a2, FUTEX_WAKE
        li    a3, 9
        sys
        li    t0, 100
        mul   t0, a0, t0
        add   s2, s2, t0
        {join("s1")}
        li    t0, 10000
        mul   t0, a1, t0
        add   s2, s2, t0
        {exit_with("s2")}
worker: li    a0, SYS_FUTEX
        li    a1, {SHARED} - 1
        li    a2, FUTEX_WAIT
        li    a3, 0
        sys
        mv    a1, a0
        addi  a1, a1, 5
        li    a0, SYS_TEXIT
        sys
"""
    # The word is a u32 as Rust lays one out, low byte in its first
    # tryte, which the word's low trits are (detrytus isa.md 5.2).
    result = run(init)
    assert result.exit_code == 0, result.console
    assert result.code_of(0) == E_AGAIN + 100 * 1 + 10000 * 5


def test_threads_asleep_on_a_futex_with_nobody_left_is_a_deadlock():
    init = f"""
        li    t0, {SHARED}
        sw    zero, 0(t0)
        {thread("worker")}
        mv    s1, a0
        {join("s1")}
        {exit_with("a0")}
worker: li    a0, SYS_FUTEX
        li    a1, {SHARED} - 1
        li    a2, FUTEX_WAIT
        li    a3, 0
        sys
        {texit(0)}
"""
    result = run(init)
    assert result.exit_code == 1
    assert "deadlock" in result.console


def test_exit_in_any_thread_ends_the_whole_process():
    # Program 1's thread exits with 9 while the first thread spins for
    # ever: the parent's wait reports 9, and every slot is free.
    prog = f"""
        {thread("worker")}
1:      j     1b
worker: {spin(2000)}
        li    a1, 9
        {EXIT}
"""
    image = build(spawn_and_wait(), prog)
    result = run_image(image)
    assert result.exit_code == 0, result.console
    assert result.code_of(0) == 1000 * WAIT_EXITED + 9
    assert "process 1 exited with code 9" in result.console
    assert process_states(result, image) == [0] * image.symbols["NPROC"]


def test_a_fault_in_a_thread_ends_the_whole_process():
    prog = f"""
        {thread("worker")}
        mv    s1, a0
        {join("s1")}
        {exit_with("a1")}
worker: li    t0, 0
        lw    t1, 0(t0)
"""
    result = run(spawn_and_wait(), prog)
    assert result.code_of(0) == 1000 * WAIT_FAULTED + LOAD_PAGE_FAULT


def test_killing_a_thread_kills_its_whole_process():
    # Init kills program 1's thread, slot 2, with KILL_ANY: program 1,
    # asleep in join, ends too, as killed, and says so once.
    prog = f"""
        {thread("worker")}
        mv    s1, a0
        {join("s1")}
        {exit_with("a1")}
worker: j     worker
"""
    kill = f"""
        {spin(20000, 6)}
        li    a0, SYS_KILL
        li    a3, SIGKILL
        li    a1, 2
        li    a2, KILL_ANY
        sys
"""
    image = build(spawn_and_wait(kill), prog)
    result = run_image(image)
    assert result.exit_code == 0, result.console
    assert result.code_of(0) == 1000 * WAIT_KILLED + 9  # SIGKILL
    assert result.console.count("killed") == 1
    assert "process 1 killed" in result.console
    assert process_states(result, image) == [0] * image.symbols["NPROC"]


def test_the_pages_go_back_only_once_every_thread_has_gone():
    # The thread blocks in recv; exit in the first thread must wait for
    # it before the pages go: a second spawn afterwards finds as many
    # free pages as before the first.
    prog = f"""
        {thread("worker")}
        {spin(2000)}
        li    a1, 0
        {EXIT}
worker: li    a0, SYS_RECV
        sys
        {texit(0)}
"""
    free = """
        li    a0, SYS_INFO
        li    a1, V_USER - 6993
        sys
        li    t0, V_USER - 6993
        lw    a0, SI_FREE(t0)"""
    init = f"""
        {free}
        mv    s3, a0
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        {wait_for("s1")}
        {free}
        sub   a1, s3, a0
        {EXIT}
"""
    result = run(init, prog)
    assert result.exit_code == 0, result.console
    assert result.code_of(0) == 0


def test_threads_run_on_two_harts_at_once():
    # Two threads spin, each then ending with the hart it is on (with
    # more than one, the one the other woke takes the second); the
    # first thread joins both and exits with 10 * one + the other, each
    # as hart + 2 so that hart -1 counts.
    worker = f"""
worker: {spin(100000)}
        li    a0, SYS_HART
        sys
        addi  a1, a0, 2
        li    a0, SYS_TEXIT
        sys
"""
    init = f"""
        {thread("worker")}
        mv    s1, a0
        {thread("worker", stack="V_USER - 4500")}
        mv    s2, a0
        {join("s1")}
        mv    s3, a1
        {join("s2")}
        li    t0, 10
        mul   s3, s3, t0
        add   s3, s3, a1
        {exit_with("s3")}
{worker}
"""
    result = run(init)
    assert result.exit_code == 0, result.console
    one, other = divmod(result.code_of(0), 10)
    if result.harts == 1:
        assert one == other == 2  # hart 0
    else:
        assert one != other
