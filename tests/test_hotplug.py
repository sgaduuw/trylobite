"""Hot-plug: harts the platform adds join in, and harts it asks to go
hand their work back and leave. Events come at fixed times; user code
first runs at about time 93000, after the kernel has booted."""

from tests.kernel import SPAWN_BOTH, run
from tests.test_harts import spin_then_hart

LONG = spin_then_hart(100_000)  # about 200000 steps of work each


def finished_on(result):
    return {result.code_of(1), result.code_of(2)}


def test_a_plugged_in_hart_joins_and_takes_work():
    result = run(SPAWN_BOTH, LONG, LONG, harts=1, plug=[(150_000, 1)])
    assert result.exit_code == 0
    assert "trylobite: hart 1 joined" in result.console
    assert finished_on(result) == {0, 1}


def test_a_hart_asked_to_go_hands_its_work_back_and_leaves():
    result = run(SPAWN_BOTH, LONG, LONG, harts=3, unplug=[(150_000, 1)])
    assert result.exit_code == 0
    assert "trylobite: hart 1 left" in result.console
    assert finished_on(result) <= {-1, 0}


def test_an_idle_hart_asked_to_go_leaves_at_once():
    # Init keeps hart 0 busy; harts -1 and +1 have nothing to do.
    init = """
        li    s0, 0
1:      addi  s0, s0, 1
        li    t0, 100000
        blt   s0, t0, 1b
        li    a0, SYS_EXIT
        li    a1, 0
        sys
    """
    result = run(init, harts=3, unplug=[(150_000, 1)])
    lines = result.console.splitlines()
    assert "trylobite: hart 1 left" in lines
    assert lines.index("trylobite: hart 1 left") < lines.index(
        "trylobite: process 0 exited with code 0"
    )


def test_a_hart_outside_the_middle_nine_is_not_started():
    result = run(SPAWN_BOTH, LONG, LONG, harts=1, plug=[(150_000, 5)])
    assert result.exit_code == 0
    assert "joined" not in result.console
    assert finished_on(result) == {0}


def test_a_removed_hart_can_come_back():
    result = run(
        SPAWN_BOTH,
        LONG,
        LONG,
        harts=3,
        unplug=[(150_000, 1)],
        plug=[(200_000, 1)],
    )
    assert result.exit_code == 0
    lines = result.console.splitlines()
    left = lines.index("trylobite: hart 1 left")
    joined = lines.index("trylobite: hart 1 joined")
    assert left < joined


def test_an_event_wakes_hart_0_when_it_has_nothing_to_do():
    # Init leaves at once and one child keeps hart -1 busy, so hart 0 is
    # idle when hart 2 arrives: only the event can wake it to start hart 2.
    init = """
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        li    a0, SYS_EXIT
        li    a1, 0
        sys
    """
    result = run(init, LONG, harts=3, plug=[(400_000, 2)])  # once init is gone
    lines = result.console.splitlines()
    assert lines.index("trylobite: process 0 exited with code 0") < lines.index(
        "trylobite: hart 2 joined"
    )  # precondition: hart 0 had nothing left to run
    assert result.exit_code == 0
    assert lines.index("trylobite: hart 2 joined") < lines.index(
        "trylobite: process 1 exited with code -1"
    )


def test_a_leaving_hart_wakes_another_for_its_process():
    # Init stays busy on hart 0, its child runs on hart -1, hart 1 waits.
    # When hart -1 leaves, only a wake-up gets the child to hart 1 instead
    # of waiting for hart 0's next slice.
    init = """
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        li    s0, 0
1:      addi  s0, s0, 1
        li    t0, 200000
        blt   s0, t0, 1b
        li    a0, SYS_EXIT
        li    a1, 0
        sys
    """
    result = run(init, LONG, harts=3, unplug=[(150_000, -1)])
    assert result.exit_code == 0
    assert "trylobite: hart -1 left" in result.console
    assert result.code_of(1) == 1


def test_a_hart_gone_before_it_was_started_can_join_later():
    # Added and asked to go at once, hart 1 is gone before hart 0 sees
    # either event. Plugged in again later, it must not find itself still
    # asked to leave.
    result = run(
        SPAWN_BOTH,
        LONG,
        LONG,
        harts=1,
        plug=[(150_000, 1), (200_000, 1)],
        unplug=[(150_000, 1)],
    )
    assert result.exit_code == 0
    assert "trylobite: hart 1 joined" in result.console
    assert "left" not in result.console
    assert finished_on(result) == {0, 1}
