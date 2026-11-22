"""The disk driver: bread and bwrite move one block between the disk and
a process's block window, a page of its own at V_BLOCK made on its first
call. A block is a page, so the window holds exactly one."""

from tests.kernel import EXIT, exit_with, new_disk, run, wait_for

E_IO, E_NOBLOCK = -14, -2  # include/layout.s
MESSAGE = "kept on a ternary disk\n"


def call(number: str, block: int) -> str:
    return f"li a0, {number}\n        li a1, {block}\n        sys"


# Read block 3 (making the window), copy MESSAGE into it, write it back.
WRITE = f"""
        {call("SYS_BREAD", 3)}
        bnez  a0, 9f
        li    s1, V_BLOCK - 9841       # the window's first tryte
        la    t1, msg
1:      lt    t0, 0(t1)
        st    t0, 0(s1)
        addi  t1, t1, 1
        addi  s1, s1, 1
        bnez  t0, 1b
        {call("SYS_BWRITE", 3)}
9:      {exit_with("a0")}
msg:    .string "{MESSAGE.strip()}\\n"
"""

# Read block 3 and print it from the window.
READ = f"""
        {call("SYS_BREAD", 3)}
        bnez  a0, 9f
        li    a0, SYS_PUTS
        li    a1, V_BLOCK - 9841
        sys
9:      {exit_with("a0")}
"""


def test_a_block_written_in_one_run_is_read_in_the_next():
    disk = (new_disk(), 4)
    assert run(WRITE, disk=disk).code_of(0) == 0
    second = run(READ, disk=disk)
    assert second.code_of(0) == 0
    assert MESSAGE in second.console
    assert disk[0].stat().st_size == 4 * 39366  # the block landed in place


def test_a_block_never_written_reads_as_zeros():
    result = run(
        f"""
        {call("SYS_BREAD", 2)}
        li    t0, V_BLOCK
        lw    a1, 9840(t0)
        add   a1, a1, a0
        {EXIT}
""",
        disk=(new_disk(), 4),
    )
    assert result.code_of(0) == 0


def test_only_blocks_on_the_disk_can_be_read_or_written():
    def tried(number, block, disk):
        program = f"{call(number, block)}\n        {exit_with('a0')}"
        return run(program, disk=disk).code_of(0)

    disk = (new_disk(), 4)
    assert tried("SYS_BREAD", 4, disk) == E_NOBLOCK
    assert tried("SYS_BWRITE", -1, disk) == E_NOBLOCK
    assert tried("SYS_BREAD", 3, disk) == 0
    assert tried("SYS_BREAD", 0, None) == E_NOBLOCK  # no disk at all


def test_puts_reaches_the_window_only_once_there_is_one():
    program = f"""
        li    a0, SYS_PUTS
        li    a1, V_BLOCK
        sys
        {exit_with("a0")}
"""
    assert run(program, disk=(new_disk(), 1)).code_of(0) == -2  # E_RANGE


# Each writer puts its own number in the middle of its own block.
def writer(block: int, value: int) -> str:
    return f"""
        {call("SYS_BREAD", block)}
        li    t0, V_BLOCK
        li    t1, {value}
        sw    t1, 0(t0)
        {call("SYS_BWRITE", block)}
        {exit_with("a0")}
"""


def test_two_processes_using_the_disk_at_once_each_get_their_block():
    # The second asks while the first's command is in flight, so it waits
    # its turn; then init reads both blocks back.
    init = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        li    a0, SYS_SPAWN
        li    a1, 2
        sys
        mv    s2, a0
        {wait_for("s1")}
        {wait_for("s2")}
        {call("SYS_BREAD", 1)}
        li    t0, V_BLOCK
        lw    s3, 0(t0)
        {call("SYS_BREAD", 2)}
        li    t0, V_BLOCK
        lw    s4, 0(t0)
        li    t0, 100
        mul   s3, s3, t0
        add   a1, s3, s4
        {EXIT}
"""
    result = run(init, writer(1, 11), writer(2, 22), disk=(new_disk(), 4))
    assert (result.code_of(1), result.code_of(2)) == (0, 0)
    assert result.code_of(0) == 1122


def test_a_window_goes_back_to_the_free_pages_when_its_process_ends():
    # 10 children one after another, each with a window, in a RAM of 20
    # pages: 12 are free, init takes 4, and a child 5 with its window, so
    # keeping windows would run out after the third.
    init = f"""
        li    s1, 10
1:      li    a0, SYS_SPAWN
        li    a1, 1
        sys
        bltz  a0, 9f
        mv    s2, a0
        {wait_for("s2")}
        bnez  a1, 8f
        addi  s1, s1, -1
        bnez  s1, 1b
        li    a0, 0
        j     9f
8:      mv    a0, a1
9:      {exit_with("a0")}
"""
    child = f"""
        {call("SYS_BREAD", 0)}
        {exit_with("a0")}
"""
    result = run(init, child, ram_pages=20, disk=(new_disk(), 1))
    assert result.code_of(0) == 0, result.console
