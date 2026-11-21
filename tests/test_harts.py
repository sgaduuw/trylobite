"""Several harts: processes run on them at once, idle ones are woken,
and only the middle nine are used."""

import re

from tests.kernel import SPAWN_BOTH, build, detrytus, exit_with, run


def spin_then_hart(rounds: int = 20000) -> str:
    """Spin without system calls, then exit with the number of the hart
    that finished the work. Only the timer interrupts it."""
    return f"""
        li    s0, 0
1:      addi  s0, s0, 1
        li    t0, {rounds}
        blt   s0, t0, 1b
        li    a0, SYS_HART
        sys
        {exit_with("a0")}
"""


SPIN_THEN_HART = spin_then_hart()


def test_processes_run_on_several_harts(harts):
    result = run(SPAWN_BOTH, SPIN_THEN_HART, SPIN_THEN_HART)
    assert result.exit_code == 0
    finished_on = {result.code_of(1), result.code_of(2)}
    if harts == 1:
        assert finished_on == {0}
    else:
        # Woken from idle by the spawns, the other harts took the work.
        assert len(finished_on) == 2
        assert finished_on <= {-1, 0, 1}


def test_parallel_work_takes_fewer_steps():
    # Long enough to outweigh booting, which zeroes pages on one hart.
    work = spin_then_hart(100_000)
    one = run(SPAWN_BOTH, work, work, harts=1)
    three = run(SPAWN_BOTH, work, work, harts=3)
    assert one.exit_code == three.exit_code == 0
    assert three.steps < 0.8 * one.steps, (three.steps, one.steps)


def test_only_the_middle_nine_harts_are_used():
    # With 27 harts present, the kernel starts -4..4 and leaves the rest
    # stopped: its per-hart tables have room for nine.
    result = run(SPAWN_BOTH, SPIN_THEN_HART, SPIN_THEN_HART, harts=27)
    assert result.exit_code == 0
    assert {result.code_of(1), result.code_of(2)} <= set(range(-4, 5))


# Let the other harts boot and go idle before init does anything, so
# that the work below can only reach them by waking them.
SETTLE = """
        li    s0, 0
9:      addi  s0, s0, 1
        li    t0, 300
        blt   s0, t0, 9b
"""


def test_new_work_wakes_an_idle_hart(harts):
    # Init keeps its hart busy after the spawn: the child can only run
    # elsewhere if a waiting hart was woken for it.
    init = f"""
        {SETTLE}
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        li    s0, 0
1:      addi  s0, s0, 1
        li    t0, 50000
        blt   s0, t0, 1b
        li    a0, SYS_EXIT
        li    a1, 0
        sys
    """
    result = run(init, SPIN_THEN_HART)
    assert (result.code_of(1) != 0) == (harts > 1)


def test_a_message_wakes_an_idle_hart_for_its_receiver(harts):
    # The receiver blocks and its hart goes idle; the sender then keeps
    # its own hart busy, so the receiver runs elsewhere only if the send
    # woke a hart for it.
    sender = f"""
        {SETTLE}
1:      li    a0, SYS_SEND
        li    a1, 2
        li    a2, 1
        sys
        bnez  a0, 1b              # until the receiver exists
        li    s0, 0
2:      addi  s0, s0, 1
        li    t0, 50000
        blt   s0, t0, 2b
        li    a0, SYS_HART
        sys
        {exit_with("a0")}
    """
    receiver = f"""
        li    a0, SYS_RECV
        sys
        li    a0, SYS_HART
        sys
        {exit_with("a0")}
    """
    result = run(SPAWN_BOTH, sender, receiver)
    assert (result.code_of(1) != result.code_of(2)) == (harts > 1)


def test_each_wake_up_goes_to_a_different_hart(harts):
    # Three busy children: with three harts each gets one.
    init = f"""
        {SETTLE}
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        li    a0, SYS_EXIT
        li    a1, 0
        sys
    """
    result = run(init, SPIN_THEN_HART)
    harts_used = {c for p, c in result.exits() if p != 0}
    assert harts_used == ({-1, 0, 1} if harts > 1 else {0})


def test_hart_reports_the_running_hart():
    hart = "li a0, SYS_HART\n        sys\n        " + exit_with("a0")
    result = run(hart, harts=1)
    assert result.code_of(0) == 0


def test_a_reused_slot_is_flushed_on_the_hart_that_ran_its_old_tenant():
    # Init stays busy on hart 0, so every child is woken onto hart -1, the
    # first waiting hart. Child A runs in slot 1 there and exits; init then
    # spawns Bs until one lands in slot 1 again. A flush on hart 0 alone,
    # where spawn runs, would leave hart -1 mapping V_USER, for slot 1's
    # ASID, to A's freed page.
    a = f"""
        la    a1, msg
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_HART
        sys
        {exit_with("a0")}
msg:    .string "A\\n"
    """
    b = a.replace('"A\\n"', '"B\\n"').replace("msg", "msg_b")
    wait = """
        li    s0, 0
8:      addi  s0, s0, 1
        li    t0, 3000
        blt   s0, t0, 8b
"""
    init = f"""
        {SETTLE}
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        {wait}
1:      li    a0, SYS_SPAWN
        li    a1, 2
        sys
        mv    s1, a0
        {wait}
        li    t0, 1
        bne   s1, t0, 1b
        li    a0, SYS_EXIT
        li    a1, 0
        sys
    """
    result = run(init, a, b, harts=3, max_steps=4_000_000)
    assert result.exit_code == 0
    # Precondition: both tenants of slot 1 ran on hart -1.
    assert [c for p, c in result.exits() if p == 1] == [-1, -1]
    assert result.console.count("A\n") == 1
    assert result.console.count("B\n") == 5


def test_harts_waiting_for_the_kernel_lock_sleep():
    # Two children keep two harts busy, so their traps meet at the lock.
    # Waiting in wrs, a hart runs a handful of instructions per wait;
    # spinning on the lock word, it runs some every step it waits. Spinning
    # cost over 100000 instructions here; sleeping costs under 20000.
    image = build(SPAWN_BOTH, SPIN_THEN_HART, SPIN_THEN_HART)
    done = detrytus(
        "run", "--ram-pages", "40", "--harts", "3", "--trace", str(image.path)
    )
    assert done.returncode == 0, done.stderr[-300:]
    start, end = image.labels["klock_take"], image.labels["klock_give"]
    pcs = re.findall(r"^\[\s*-?\d+\s+(-?\d+) r", done.stderr, re.M)
    in_lock = sum(1 for pc in pcs if start <= int(pc) < end)
    assert 0 < in_lock < 30_000, in_lock
