"""The disk server (user/diskd.s) and what the kernel gives a driver
(kernel/rust/trykern/src/devices.rs): a disk call moves one block between the disk and a
page-sized buffer of the caller's, usually a block window, which
SYS_WINDOW makes. The server drives the block device: its registers are
mapped into it, and its interrupts come to it as notices."""

from tests.kernel import EXIT, exit_with, new_disk, wait_for
from tests.kernel import run as run_kernel
from tests.test_files import L, report, said
from tests.test_spawnw import disk_with, program, start_from
from tools.fs import program_file

MESSAGE = "kept on a ternary disk\n"


def run(*args, **kwargs):
    """A run with the disk server, process 1, started first."""
    return run_kernel(*args, disk_server=True, **kwargs)


def disk_call(op: str, block: int | str, buffer: str = "V_BLOCK") -> str:
    """A call to the disk server; a0 is how it went."""
    return f"""
        CALL_DISK
        li    a2, {op}
        li    a3, {block}
        li    a4, {buffer}
        sys"""


WINDOW = "li a0, SYS_WINDOW\n        li a1, 0\n        sys"

# Read block 3, copy MESSAGE into it, write it back.
WRITE = f"""
        {WINDOW}
        {disk_call("DK_READ", 3)}
        bnez  a0, 9f
        li    s1, V_BLOCK - 9841       # the window's first tryte
        la    t1, msg
1:      lt    t0, 0(t1)
        st    t0, 0(s1)
        addi  t1, t1, 1
        addi  s1, s1, 1
        bnez  t0, 1b
        {disk_call("DK_WRITE", 3)}
9:      {exit_with("a0")}
msg:    .string "{MESSAGE.strip()}\\n"
"""

# Read block 3 and print it from the window.
READ = f"""
        {WINDOW}
        {disk_call("DK_READ", 3)}
        bnez  a0, 9f
        li    a0, SYS_PUTS
        li    a1, V_BLOCK - 9841
        sys
9:      {exit_with("a0")}
"""


def test_a_block_written_in_one_run_is_read_in_the_next():
    # init waits for the server, which waits for the disk's interrupt:
    # not a deadlock, since the disk is armed.
    disk = (new_disk(), 4)
    first = run(WRITE, disk=disk)
    assert first.code_of(0) == 0, first.console
    second = run(READ, disk=disk)
    assert second.code_of(0) == 0
    assert MESSAGE in second.console
    assert disk[0].stat().st_size == 4 * 39366  # the block landed in place


def test_a_block_never_written_reads_as_zeros():
    result = run(
        f"""
        {WINDOW}
        li    t0, V_BLOCK              # something to overwrite
        li    t1, 5
        sw    t1, 9840(t0)
        {disk_call("DK_READ", 2)}
        li    t0, V_BLOCK
        lw    a1, 9840(t0)
        add   a1, a1, a0
        {EXIT}
""",
        disk=(new_disk(), 4),
    )
    assert result.code_of(0) == 0


def test_a_disk_call_says_what_is_wrong_with_it():
    program = report(
        WINDOW,
        disk_call("DK_READ", 4),  # past the end
        disk_call("DK_WRITE", -1),
        disk_call("DK_READ", 3),
        disk_call(2, 3),  # no such operation
        disk_call("DK_READ", 3, "V_BLOCK + PAGE"),  # no window there
        disk_call("DK_WRITE", 3, "V_BLOCK + 9"),  # runs off the window
    )
    assert said(run(program, disk=(new_disk(), 4))) == [
        0,
        L["E_NOBLOCK"],
        L["E_NOBLOCK"],
        0,
        L["E_INVAL"],
        L["E_FAULT"],
        L["E_FAULT"],
    ]
    no_disk = report(WINDOW, disk_call("DK_READ", 0))
    assert said(run(no_disk)) == [0, L["E_NOBLOCK"]]


def test_puts_reaches_the_window_only_once_there_is_one():
    program = report(
        "li a0, SYS_PUTS\n        li a1, V_BLOCK\n        sys",
        WINDOW,
        "li a0, SYS_PUTS\n        li a1, V_BLOCK\n        sys",  # an empty string
        "li a0, SYS_WINDOW\n        li a1, NWIN\n        sys",
    )
    assert said(run_kernel(program)) == [L["E_RANGE"], 0, 0, L["E_INVAL"]]


# Each writer puts its own number in the middle of its own block.
def writer(block: int, value: int) -> str:
    return f"""
        {WINDOW}
        li    t0, V_BLOCK
        li    t1, {value}
        sw    t1, 0(t0)
        {disk_call("DK_WRITE", block)}
        {exit_with("a0")}
"""


def test_two_processes_using_the_disk_at_once_each_get_their_block():
    # The second asks while the first's command is in flight, so the
    # server keeps its call until the disk is free; then init reads both
    # blocks back.
    init = f"""
        .gp   USER_GP
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
        {WINDOW}
        {disk_call("DK_READ", 1)}
        li    t0, V_BLOCK
        lw    s3, 0(t0)
        {disk_call("DK_READ", 2)}
        li    t0, V_BLOCK
        lw    s4, 0(t0)
        li    t0, 100
        mul   s3, s3, t0
        add   a1, s3, s4
        {EXIT}
"""
    result = run(init, writer(1, 11), writer(2, 22), disk=(new_disk(), 4))
    assert (result.code_of(2), result.code_of(3)) == (0, 0)
    assert result.code_of(0) == 1122


def test_a_client_killed_with_its_block_in_flight_leaves_the_server_usable():
    # The child asks for a block and is killed while the disk reads it;
    # the server finds nobody to copy it to, and init's read still works.
    child = f"""
        {WINDOW}
        {disk_call("DK_READ", 1)}
        {exit_with("a0")}
"""
    init = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
1:      li    a0, SYS_YIELD            # until the server has taken the
        sys                            # child's call, and started the disk
        li    a0, SYS_PROC             # on it
        mv    a1, s1
        la    a2, info
        sys
        la    t0, info
        lw    t0, PI_STATE(t0)
        li    t1, ST_REPLY
        bne   t0, t1, 1b
        li    a0, SYS_KILL
        mv    a1, s1
        li    a2, FOR_SELF
        sys
        {wait_for("s1")}
        mv    s3, a0
        {WINDOW}
        {disk_call("DK_READ", 1)}
        li    t0, 10
        mul   a1, s3, t0
        add   a1, a1, a0
        {EXIT}
        .align 1
info:   .words PROCINFO / 3
"""
    result = run(init, child, disk=(new_disk(), 4))
    assert result.code_of(0) == L["WAIT_KILLED"] * 10


# --- what a driver gets ----------------------------------------------------------


def drive(source: str = "SRC_DISK") -> str:
    return f"li a0, SYS_DRIVE\n        li a1, {source}\n        sys"


def test_a_driver_sees_the_device_and_its_own_physical_memory():
    program = report(
        "li a0, SYS_PHYS\n        li a1, V_USER\n        sys",  # not a driver yet
        "li a0, SYS_ARM\n        li a1, SRC_DISK\n        sys",
        drive("NSRC + 1"),  # no such source
        drive(0),
        drive(),
        drive(),  # its own again
        # The disk's BLOCKS register, mapped for it.
        "li t0, V_DEVICE + PAGE * (SRC_DISK - 1)\n        lw a0, DISK_BLOCKS(t0)",
        # Physical addresses run as virtual ones do within a page.
        "li a0, SYS_PHYS\n        li a1, V_USER + 1\n        sys\n        mv s1, a0\n"
        "        li a0, SYS_PHYS\n        li a1, V_USER\n        sys\n"
        "        sub a0, s1, a0",
        "li a0, SYS_PHYS\n        li a1, V_BLOCK\n        sys",  # no window
    )
    result = run_kernel(program, disk=(new_disk(), 7))
    assert said(result) == [
        L["E_PERM"],
        L["E_PERM"],
        L["E_INVAL"],
        L["E_INVAL"],
        0,
        0,
        7,
        1,
        L["E_FAULT"],
    ]


def test_a_device_has_one_driver_until_it_ends():
    # The disk server drives the disk, so init cannot; once it is killed,
    # init can.
    program = report(
        "li a0, SYS_LOOKUP\n        la a1, name\n        li a2, LOOKUP_WAIT\n"
        "        sys\n        mv s1, a0",
        drive(),
        "li a0, SYS_KILL\n        mv a1, s1\n        li a2, FOR_SELF\n        sys",
        wait_for("s1") + "\n        mv    a0, a1",
        drive(),
        data='name: .string "disk"\n',
    )
    assert said(run(program, disk=(new_disk(), 1))) == [
        1,
        L["E_BUSY"],
        0,
        0,
        0,
    ]


def test_a_program_file_cannot_drive_a_device():
    # A device moves memory without asking, so only programs in the
    # kernel's image may drive one.
    body = f"""
        {drive()}
        mv    a1, a0
        li    a0, SYS_EXIT
        sys
"""
    disk, first = disk_with(d=program_file(program(body)))
    result = run_kernel(start_from(first["d"]), disk=disk, disk_server=True)
    assert result.code_of(0) == L["E_PERM"]
