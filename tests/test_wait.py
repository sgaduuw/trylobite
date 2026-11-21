"""wait: exit codes outlive their process until the parent asks."""

from tests.kernel import (
    EXIT,
    LOAD_PAGE_FAULT,
    SPAWN_BOTH,
    build,
    exit_with,
    run,
    run_image,
    wait_for,
)

E_NOCHILD = -2  # include/layout.s
WAIT_EXITED, WAIT_FAULTED = 0, 1


def spin(rounds: int) -> str:
    return f"""
        li    s0, 0
7:      addi  s0, s0, 1
        li    t0, {rounds}
        blt   s0, t0, 7b"""


def spawn_and_wait(program: int = 1, before_wait: str = "") -> str:
    """Spawn a program, wait for it, and exit with 1000 * how it ended +
    its code, so one exit code carries both."""
    return f"""
        li    a0, SYS_SPAWN
        li    a1, {program}
        sys
        mv    s1, a0
        {before_wait}
        {wait_for("s1")}
        li    t0, 1000
        mul   a0, a0, t0
        add   a1, a0, a1
        {EXIT}
"""


def exit_code(code: int) -> str:
    return f"li a1, {code}\n        {EXIT}"


def test_wait_blocks_until_the_child_exits_and_returns_its_code():
    result = run(spawn_and_wait(), spin(5000) + "\n        " + exit_code(42))
    assert result.code_of(1) == 42
    assert result.code_of(0) == 1000 * WAIT_EXITED + 42


def test_an_exit_code_can_be_negative_without_looking_like_a_failure():
    # -2 is also E_NOCHILD: it comes back in a1, so the two cannot meet.
    result = run(spawn_and_wait(), exit_code(-2))
    assert result.code_of(0) == 1000 * WAIT_EXITED - 2


def test_wait_on_a_child_that_already_ended_returns_at_once():
    result = run(spawn_and_wait(before_wait=spin(5000)), exit_code(7))
    assert result.code_of(0) == 1000 * WAIT_EXITED + 7


def test_wait_reports_a_child_that_faulted_and_why():
    fault = "li t0, 0\n        lw t1, 0(t0)"  # page 0 is never mapped
    result = run(spawn_and_wait(), fault)
    assert result.code_of(0) == 1000 * WAIT_FAULTED + LOAD_PAGE_FAULT


def test_a_parent_waiting_for_one_child_is_not_woken_by_another():
    # Program 2 ends first, once init is waiting (the spawn's length can
    # cost init its slice before it gets to wait): init waits for program 1
    # and must get its code.
    init = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        li    a0, SYS_SPAWN
        li    a1, 2
        sys
        {wait_for("s1")}
        {exit_with("a1")}
"""
    slow = spin(20000) + "\n        " + exit_code(1)
    fast = spin(3000) + "\n        " + exit_code(2)
    result = run(init, slow, fast)
    assert result.code_of(0) == 1
    assert result.exits().index((2, 2)) < result.exits().index((1, 1))


def test_wait_refuses_what_is_not_a_child():
    own = f"li a0, SYS_GETPID\n        sys\n        {wait_for('a0')}"
    for target in ("li s1, 4", "li s1, -1", "li s1, 6", own):
        init = f"{target}\n        {wait_for('s1')}\n        {exit_with('a0')}"
        assert run(init).code_of(0) == E_NOCHILD, target
    # A sibling, spawned by init, is not program 1's child either.
    sibling = f"li s1, 2\n        {wait_for('s1')}\n        {exit_with('a0')}"
    result = run(SPAWN_BOTH, sibling, spin(3000) + "\n        " + exit_code(0))
    assert result.code_of(1) == E_NOCHILD


def test_a_parent_waiting_on_a_child_that_never_ends_is_a_deadlock():
    recv = "li a0, SYS_RECV\n        sys\n        " + exit_code(0)
    result = run(spawn_and_wait(), recv)
    assert result.exit_code == 1
    assert "deadlock" in result.console


def process_states(result, image) -> list[int]:
    k = image.symbols
    procs = image.labels["procs"] + k["KOFF"]  # physical address
    slots = range(k["NPROC"])
    return result.words([procs + s * k["PCB_SIZE"] + k["PCB_STATE"] for s in slots])


def test_children_of_an_exited_parent_leave_nothing_behind():
    # Program 1 spawns program 2, which ends at once and so waits as a
    # zombie, then exits without waiting for it; init has already gone
    # without waiting for program 1. Every record must end up free.
    parent = f"""
        li    a0, SYS_SPAWN
        li    a1, 2
        sys
        {spin(5000)}
        {exit_code(0)}
"""
    init = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        {exit_code(0)}
"""
    image = build(init, parent, exit_code(5))
    result = run_image(image)
    assert result.exit_code == 0
    assert sorted(result.exits()) == [(0, 0), (1, 0), (2, 5)]
    assert process_states(result, image) == [0] * 6


def test_a_reaped_child_frees_its_slot_for_the_next_spawn():
    # NPROC is 6: init and a child at a time, spawned and reaped 8 times.
    # Without reaping, the sixth spawn would find no free slot.
    init = f"""
        li    s2, 0
1:      li    a0, SYS_SPAWN
        li    a1, 1
        sys
        bltz  a0, 2f
        mv    s1, a0
        {wait_for("s1")}
        addi  s2, s2, 1
        li    t0, 8
        blt   s2, t0, 1b
2:      {exit_with("s2")}
"""
    assert run(init, exit_code(0)).code_of(0) == 8
