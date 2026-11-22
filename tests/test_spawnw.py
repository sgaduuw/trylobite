"""spawnw: start a program from a file. The caller reads the file's first
block into its block window, from the disk server, and the kernel copies the image after
EXEC_MAGIC into a fresh page at V_USER (include/layout.s). tools/fs.py
makes the program files, from images assembled to run at V_USER."""

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


def disk_with(**files: list[int] | str):
    """A disk holding these files; returns it and each file's first block."""
    path = new_disk()
    made = Filesystem.new(5)
    for name, contents in files.items():
        if isinstance(contents, str):
            made.write(name, contents)
        else:
            made.write_trytes(name, contents)
    made.save(path)
    first = {name: node.direct[0] for name, node in made.listdir()}
    return (path, 5), first


def start_from(
    block: int,
    window: int = 0,
    parent: str = "FOR_SELF",
    args: str = "0",
    n: str = "0",
) -> str:
    """Read block into the window, spawnw with n trytes of arguments at
    args, and exit with the child's code, or with spawnw's failure. The
    disk server is process 1."""
    return f"""
        li    a0, SYS_WINDOW
        li    a1, {window}
        sys
        CALL_DISK
        li    a2, DK_READ
        li    a3, {block}
        li    a4, V_BLOCK + PAGE * {window}
        sys
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


def test_a_program_file_is_the_magic_word_and_the_image(tmp_path):
    dti = tmp_path / "greet.dti"
    dti.write_bytes(GREET)
    image = tmp_path / "disk.img"
    assert fs.main(["new", str(image), "6", str(dti)]) == 0
    made = Filesystem.load(image)
    trytes = made.read_trytes("bin/greet")  # named after the file, less .dti
    assert fs.join_word(trytes[:3]) == fs.L["EXEC_MAGIC"]
    assert trytes[0] < 0  # which no text file's first tryte is
    assert "hello from the disk" in "".join(chr(t) for t in trytes if t > 0)
    with pytest.raises(FsError, match="a program, not text"):
        made.read("bin/greet")


def test_a_program_must_run_from_v_user_and_fit_its_page():
    with pytest.raises(FsError, match="V_USER"):
        program_file(program(".org V_USER - 9840\n        .word 1"))
    with pytest.raises(FsError, match="V_USER"):
        program_file(program(".zero 9844"))
    assert len(program_file(program(".zero 9843"))) == 3 + fs.L["EXEC_MAX"]
