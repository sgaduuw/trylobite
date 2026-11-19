"""Process creation, the page allocator and reclaimed memory."""

from tests.kernel import DONE, EXIT, build, exit_with, run, run_image

WAIT = "li a0, SYS_RECV\n        sys\n        " + DONE  # holds its pages


def spawn(program: int, into: str = "a0") -> str:
    move = "" if into == "a0" else f"\n        mv    {into}, a0"
    return f"li    a0, SYS_SPAWN\n        li    a1, {program}\n        sys{move}"


def test_spawn_returns_process_numbers():
    init = f"""
        {spawn(1, "s0")}
        {spawn(2, "s1")}
        li    t0, 3
        mul   a1, s0, t0
        add   a1, a1, s1          # 3 * first + second
        {EXIT}
    """
    assert run(init).code_of(0) == 3 * 1 + 2


def test_spawning_a_missing_program_fails():
    init = f"""
        {spawn(3, "s0")}
        {spawn(-1, "s1")}
        add   a1, s0, s1
        {EXIT}
    """
    assert run(init).code_of(0) == -4


def test_each_spawn_runs_its_own_copy_of_the_program():
    # The program counts in its own memory; spawned twice, both copies
    # start from the image, so both count to 1.
    counter = f"""
        la    t0, count
        lw    t1, 0(t0)
        addi  t1, t1, 1
        sw    t1, 0(t0)
        {exit_with("t1")}
count:  .word 0
    """
    result = run(f"{spawn(1)}\n        {spawn(1)}\n        {DONE}", counter)
    assert [c for p, c in result.exits() if p in (1, 2)] == [1, 1]


def test_spawn_fails_when_memory_runs_out():
    # Pages 9..16 hold two processes of four pages: init and one child.
    init = f"""
        {spawn(1)}
        {spawn(1)}
        mv    a1, a0
        {EXIT}
    """
    result = run(init, WAIT, ram_pages=16)
    assert result.code_of(0) == -3


def test_spawn_fails_when_the_table_is_full():
    # Room in memory for eight processes, but only six slots.
    calls = "\n        ".join(spawn(1) for _ in range(5))
    init = f"""
        {calls}
        {spawn(1)}
        mv    a1, a0
        {EXIT}
    """
    result = run(init, WAIT, max_steps=3_000_000)
    assert result.code_of(0) == -1


def test_exited_processes_give_their_memory_back():
    # Memory for init and one child only, yet init starts four children in
    # turn: each spawn succeeds only once the previous child's pages return.
    init = f"""
        li    s0, 0
1:      {spawn(1)}
        bgez  a0, 2f
        li    a0, SYS_YIELD          # no memory yet: let the child finish
        sys
        j     1b
2:      addi  s0, s0, 1
        li    t0, 4
        blt   s0, t0, 1b
        {DONE}
    """
    result = run(init, DONE, ram_pages=16, max_steps=3_000_000)
    assert result.exit_code == 0
    assert sum(1 for p, _ in result.exits() if p != 0) == 4  # every child exited


def test_a_reused_slot_does_not_see_its_old_tenants_translations():
    # Program 1 ("A") runs in slot 1 and exits. Init then spawns program 2
    # ("B") until one lands in slot 1 again, and so gets the same ASID.
    # Without a fence.vm the TLB would still map V_USER to A's freed page,
    # and that B would print A or crash.
    first = """
        la    a1, msg_a
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_SEND
        li    a1, 0
        li    a2, 1
        sys
        li    a0, SYS_EXIT
        li    a1, 0
        sys
msg_a:  .string "A\\n"
    """
    second = """
        la    a1, msg_b
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_EXIT
        li    a1, 0
        sys
msg_b:  .string "B\\n"
    """
    init = f"""
        {spawn(1)}
        li    a0, SYS_RECV           # A says it is done
        sys
        li    a0, SYS_YIELD          # and exits
        sys
1:      {spawn(2)}
        li    t0, 1
        beq   a0, t0, 2f
        li    a0, SYS_YIELD          # let this B finish, freeing its slot
        sys
        j     1b
2:      {DONE}
    """
    result = run(init, first, second, max_steps=4_000_000)
    assert result.exit_code == 0
    assert result.console.count("A\n") == 1
    # Slots 2 to 5, then slot 1 again (slot 0 is init's): five Bs.
    assert result.console.count("B\n") == 5
    assert [p for p, _ in result.exits()].count(1) == 2


def test_a_recycled_page_table_starts_empty():
    # Program 1 exits and frees its pages; program 2 is then built from
    # them and left blocked, so the machine halts with it alive. Its leaf
    # table must hold exactly one entry, the process's own page, whatever
    # the page held before: a stale entry could map memory it should never
    # see.
    first = (
        "li a0, SYS_SEND\n        li a1, 0\n        li a2, 1\n        sys\n        "
        + DONE
    )
    init = f"""
        {spawn(1)}
        li    a0, SYS_RECV
        sys
        li    a0, SYS_YIELD
        sys
        {spawn(2)}
        {DONE}
    """
    image = build(init, first, WAIT)
    result = run_image(image)
    assert result.exit_code == 1  # deadlock: program 2 waits forever
    k = image.symbols
    bus = result.machine.bus

    def record(slot: int, offset: int) -> int:
        procs = image.labels["procs"] + k["KOFF"]  # physical address
        return bus.read(procs + slot * k["PCB_SIZE"] + offset, 3)

    pages = ("PCB_ROOTPG", "PCB_MIDPG", "PCB_LEAFPG", "PCB_USERPG")
    first_pages = {record(1, k[p]) for p in pages}
    leaf = record(2, k["PCB_LEAFPG"])
    assert leaf in first_pages  # precondition: the table really was recycled
    centre = leaf * k["PAGE"]
    entries = [bus.read(centre + 3 * i, 3) for i in range(-3280, 3281)]
    assert sum(1 for e in entries if e) == 1
    assert entries[3280] != 0  # index 0: the process's page
