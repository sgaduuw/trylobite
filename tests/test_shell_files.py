"""The shell's file built-ins, ls, cat, write and rm, on the filesystem of
docs/filesystem.md. tools/fs.py makes the disks and checks what the shell
left on them."""

import pytest

from tests.kernel import ROOT, assemble_file, new_disk, run_image
from tools.fs import PAGE, Filesystem


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def disk(blocks: int = 4, **files: str):
    """A new disk holding a filesystem with these files: (path, blocks)."""
    path = new_disk()
    made = Filesystem.new(blocks)
    for name, text in files.items():
        made.write(name, text)
    made.save(path)
    return path, blocks


def said(shell, typed: str, on) -> str:
    """What the shell printed between booting and its exit."""
    result = run_image(shell, input=typed, disk=on, max_steps=5_000_000)
    assert result.exit_code == 0, result.console
    console = result.console.removeprefix("trylobite: booting\n")
    return console.split("trylobite: process 0 exited")[0]


def test_ls_lists_each_file_with_its_size(shell):
    on = disk(notes="kept on a ternary disk\n", empty="")
    assert said(shell, "ls\n", on) == "$ ls\n23 notes\n0 empty\n$ \n"


def test_cat_prints_a_file(shell):
    on = disk(notes="line one\nline two\n", empty="")
    assert said(shell, "cat notes\ncat empty\n", on) == (
        "$ cat notes\nline one\nline two\n$ cat empty\n$ \n"
    )


def test_cat_follows_a_file_over_several_blocks(shell):
    text = "".join(chr(ord("a") + i % 26) for i in range(2 * PAGE + 5)) + "\n"
    on = disk(5, big=text)
    assert said(shell, "cat big\n", on) == f"$ cat big\n{text}$ \n"


def test_write_makes_a_file_the_tool_can_read(shell):
    on = disk()
    out = said(shell, "write motd  welcome to   ternary\ncat motd\n", on)
    assert (
        out
        == "$ write motd  welcome to   ternary\n$ cat motd\nwelcome to   ternary\n$ \n"
    )
    made = Filesystem.load(on[0])
    assert made.read("motd") == "welcome to   ternary\n"
    assert made.free_blocks() == [2, 3]


def test_write_replaces_a_file_and_frees_its_old_block(shell):
    on = disk(motd="old\n")
    said(shell, "write motd new text\n", on)
    made = Filesystem.load(on[0])
    assert made.read("motd") == "new text\n"
    assert [e.name for e in made.entries()] == ["motd"]
    assert made.free_blocks() == [1, 3]  # the new text went to block 2


def test_rm_removes_a_file_and_frees_its_blocks(shell):
    on = disk(a="first\n", b="second\n")
    assert said(shell, "rm a\nls\ncat a\n", on) == (
        "$ rm a\n$ ls\n7 b\n$ cat a\nsh: no such file: a\n$ \n"
    )
    made = Filesystem.load(on[0])
    assert [e.name for e in made.entries()] == ["b"]
    assert made.free_blocks() == [1, 3]


def test_a_full_disk_is_refused_and_keeps_the_old_file(shell):
    on = disk(2, a="first\n")  # block 1 is the only data block, and a's
    assert "sh: the disk is full\n" in said(shell, "write a again\n", on)
    assert Filesystem.load(on[0]).read("a") == "first\n"


def test_a_full_directory_is_refused(shell):
    names = {f"f{i}": "" for i in range(64)}
    on = disk(3, **names)
    assert "sh: the directory is full\n" in said(shell, "write more x\n", on)


def test_names_must_be_given_and_fit(shell):
    on = disk()
    long, longest = "x" * 18, "y" * 17
    out = said(shell, f"cat\nrm   \nwrite {long} no\nwrite {longest} ok\n", on)
    assert out.count("sh: which file?\n") == 2
    assert "sh: a name has at most 17 characters\n" in out
    assert Filesystem.load(on[0]).read(longest) == "ok\n"


def test_a_disk_without_a_filesystem_is_reported(shell):
    blank = (new_disk(), 3)
    assert said(shell, "ls\n", blank) == (
        "$ ls\nsh: cannot read the filesystem: -4\n$ \n"
    )
    assert "sh: cannot read the filesystem: -2\n" in said(shell, "cat x\n", None)
