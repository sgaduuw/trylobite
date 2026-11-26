"""spawnw: start a program from a file. The caller reads the file's blocks
into consecutive block windows, from the disk server, and the kernel
copies the image after EXEC_MAGIC and its size into a fresh page at
V_USER, and the pages above it as far as it reaches (include/layout.s).
tools/fs.py makes the program files, from images assembled to run at
V_USER."""

import pytest

from tests.kernel import _assemble, exit_with, new_disk, wait_for
from tests.kernel import run as run_kernel
from tools import fs
from tools.fs import Filesystem, FsError, program_file

E_NOPROG = -2  # include/layout.s


def run(*args, **kwargs):
    return run_kernel(*args, disk_server=True, **kwargs)


def program(body: str) -> bytes:
    """A program assembled on its own, as a disk program is."""
    image = _assemble(
        ["-"],
        stdin=f"""
        .include "include/layout.s"
        .section disk, V_USER, V_USER
        .gp   USER_GP
{body}
""",
    )
    return image.path.read_bytes()


def disk_with(blocks: int = 5, **files: list[int] | str):
    """A disk holding these files; returns it and each file's first block."""
    path, first, _ = disk_blocks(blocks, **files)
    return path, first


def disk_blocks(blocks: int = 5, **files: list[int] | str):
    """As disk_with, and each file's blocks too."""
    path = new_disk()
    made = Filesystem.new(blocks)
    for name, contents in files.items():
        if isinstance(contents, str):
            made.write(name, contents)
        else:
            made.write_trytes(name, contents)
    made.save(path)
    first = {name: node.direct[0] for name, node in made.listdir()}
    every = {name: made.block_list(node) for name, node in made.listdir()}
    return (path, blocks), first, every


def read_into(window: int, block: int) -> str:
    """Make the window, and read block into it from the disk server,
    process 1."""
    return f"""
        li    a0, SYS_WINDOW
        li    a1, {window}
        sys
        CALL_DISK
        li    a2, DK_READ
        li    a3, {block}
        li    a4, V_BLOCK + PAGE * {window}
        sys
"""


def start_from(
    block: int | list[int],
    window: int = 0,
    parent: str = "FOR_SELF",
    args: str = "0",
    n: str = "0",
) -> str:
    """Read the block, or each of a list into the windows from this one on,
    spawnw with n trytes of arguments at args, and exit with the child's
    code, or with spawnw's failure."""
    blocks = block if isinstance(block, list) else [block]
    reads = "".join(read_into(window + k, b) for k, b in enumerate(blocks))
    return f"""
{reads}
        li    a0, SYS_SPAWNW
        li    a1, {window}
        li    a2, {parent}
        li    a3, {args}
        li    a4, {n}
        sys
        bltz  a0, 9f
        mv    s1, a0
        {wait_for("s1")}
        mv    a0, a1
9:      {exit_with("a0")}
"""


GREET = program("""
        la    a1, msg
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_EXIT
        li    a1, 42
        sys
msg:    .string "hello from the disk\\n"
""")


def test_a_program_file_runs_from_the_window():
    disk, first = disk_with(greet=program_file(GREET))
    result = run(start_from(first["greet"]), disk=disk)
    assert "hello from the disk\n" in result.console
    assert result.code_of(2) == 42  # the child
    assert result.code_of(0) == 42  # and its parent, which waited for it


def test_the_whole_image_lands_and_nothing_else():
    # The image's last word sits at the page's top word; below V_USER the
    # page is clear, and the child has no window of its own.
    body = """
        li    t0, V_USER - 9840
        lw    a1, 0(t0)
        lw    t1, last
        add   a1, a1, t1
        li    a0, SYS_PUTS
        li    a1, V_BLOCK
        sys                            # E_RANGE: no window
        lw    t1, last
        add   a1, a0, t1
        li    a0, SYS_EXIT
        sys
        .org  V_USER + 9840
last:   .word 77
"""
    disk, first = disk_with(top=program_file(program(body)))
    result = run(start_from(first["top"]), disk=disk)
    assert result.code_of(2) == 77 + -2  # E_RANGE


# A program of three blocks: code in its own page, words in the two pages
# above it, the last at the top of the third block's reach, and its sum
# as the exit code. Its stack is below V_USER, clear of all of it.
BIG = program("""
        lw    a1, one
        lw    t0, two
        add   a1, a1, t0
        lw    t0, three
        add   a1, a1, t0
        addi  sp, sp, -3               # the stack: below the image
        sw    a1, 0(sp)
        lw    a1, 0(sp)
        li    a0, SYS_EXIT
        sys
        .org  V_USER + PAGE
one:    .word 100
        .org  V_USER + 2 * PAGE
two:    .word 20
        .org  V_USER - 1 + 3 * PAGE - 6 - 2
three:  .word 3
""")


def test_a_program_of_several_blocks_runs_from_as_many_windows():
    file = program_file(BIG)
    assert len(file) == 3 * fs.PAGE  # three blocks, the last one full
    disk, _, every = disk_blocks(8, big=file)
    assert len(every["big"]) == 3
    result = run(start_from(every["big"]), disk=disk)
    assert result.code_of(2) == 123
    assert result.code_of(0) == 123
    # From any window, so long as the rest follow it.
    assert run(start_from(every["big"], window=6), disk=disk).code_of(0) == 123


def test_every_block_must_be_in_the_windows():
    disk, _, every = disk_blocks(8, big=program_file(BIG))
    # Only the first two: the third window is not there.
    assert run(start_from(every["big"][:2]), disk=disk).code_of(0) == E_NOPROG
    # The last window cannot have a block after it.
    assert run(start_from(every["big"], window=7), disk=disk).code_of(0) == E_NOPROG


def test_an_image_larger_than_the_windows_hold_is_refused():
    head = fs.split_word(fs.L["EXEC_MAGIC"]) + fs.split_word(fs.L["EXEC_MAX"] + 1)
    disk, first = disk_with(huge=head + [0] * 30)
    assert run(start_from(first["huge"]), disk=disk).code_of(0) == E_NOPROG
    head = fs.split_word(fs.L["EXEC_MAGIC"]) + fs.split_word(-1)
    disk, first = disk_with(neg=head + [0] * 30)
    assert run(start_from(first["neg"]), disk=disk).code_of(0) == E_NOPROG


def test_a_large_program_gives_its_pages_back():
    # Start BIG, wait for it, and count the free pages before and after:
    # its image's pages above its own go back too.
    disk, _, every = disk_blocks(8, big=program_file(BIG))
    free = """
        li    a0, SYS_INFO
        la    a1, info
        sys
        la    t0, info
        lw    {reg}, SI_FREE(t0)
"""
    reads = "".join(read_into(k, b) for k, b in enumerate(every["big"]))
    body = f"""
{reads}
{free.format(reg="s2")}
        li    a0, SYS_SPAWNW
        li    a1, 0
        li    a2, FOR_SELF
        li    a3, 0
        li    a4, 0
        sys
        mv    s1, a0
        {wait_for("s1")}
{free.format(reg="s3")}
        sub   a0, s3, s2
        {exit_with("a0")}
info:   .words SYSINFO / 3
"""
    assert run(body, disk=disk).code_of(0) == 0


def test_text_is_not_a_program():
    disk, first = disk_with(notes="li a0, SYS_EXIT\n")
    assert run(start_from(first["notes"]), disk=disk).code_of(0) == E_NOPROG


def test_any_window_will_do_but_only_for_a_caller_held():
    disk, first = disk_with(greet=program_file(GREET))
    assert run(start_from(first["greet"], window=8), disk=disk).code_of(0) == 42
    # A parent other than the caller must be a process whose call it holds:
    # init holds nobody's.
    result = run(start_from(first["greet"], parent="0"), disk=disk)
    assert result.code_of(0) == -2  # E_NOPROC


def test_there_is_nothing_to_start_without_a_window():
    program = f"""
        li    a0, SYS_SPAWNW
        li    a1, 0
        li    a2, FOR_SELF
        sys
        {exit_with("a0")}
"""
    assert run(program).code_of(0) == E_NOPROG


# --- tools/fs.py: program files -------------------------------------------------


def test_a_program_file_is_the_magic_word_the_size_and_the_image(tmp_path):
    dti = tmp_path / "greet.dti"
    dti.write_bytes(GREET)
    image = tmp_path / "disk.img"
    assert fs.main(["new", str(image), "6", str(dti)]) == 0
    made = Filesystem.load(image)
    trytes = made.read_trytes("bin/greet")  # named after the file, less .dti
    assert fs.join_word(trytes[:3]) == fs.L["EXEC_MAGIC"]
    assert fs.join_word(trytes[3:6]) == len(trytes) - fs.L["EXEC_HEAD"]
    assert trytes[0] < 0  # which no text file's first tryte is
    assert "hello from the disk" in "".join(chr(t) for t in trytes if t > 0)
    with pytest.raises(FsError, match="a program, not text"):
        made.read("bin/greet")


def test_a_program_must_run_from_v_user_and_fit_the_windows():
    most = fs.L["EXEC_MAX"]
    with pytest.raises(FsError, match="V_USER"):
        program_file(program(".org V_USER - 9840\n        .word 1"))
    with pytest.raises(FsError, match="V_USER"):
        program_file(program(f".zero {most + 1}"))
    assert len(program_file(program(f".zero {most}"))) == fs.L["NWIN"] * fs.PAGE
