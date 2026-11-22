"""The shell's file built-ins, ls, cat, write, rm, mkdir and rmdir, on the
filesystem of docs/filesystem.md, through the file server. tools/fs.py makes
the disks."""

import pytest

from tests.kernel import ROOT, assemble_file, new_disk, run_image
from tools.fs import PAGE, Filesystem


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def disk(blocks: int = 8, dirs: tuple[str, ...] = (), **files: str):
    """A new disk holding a filesystem with these directories and text
    files: (path, blocks). A file's name may hold slashes, as __ ."""
    path = new_disk()
    made = Filesystem.new(blocks)
    for name in dirs:
        made.mkdir(name)
    for name, text in files.items():
        made.write(name.replace("__", "/"), text)
    made.save(path)
    return path, blocks


def said(shell, typed: str, on) -> str:
    """What the shell printed between booting and its exit."""
    result = run_image(shell, input=typed, disk=on, max_steps=5_000_000)
    assert result.exit_code == 0, result.console
    console = result.after_boot
    return console.split("trylobite: process 5 exited")[0]  # the shell


def test_ls_lists_each_file_with_its_size(shell):
    on = disk(notes="kept on a ternary disk\n", empty="")
    assert said(shell, "ls\n", on) == "$ ls\n23 notes\n0 empty\n$ \n"


def test_ls_marks_directories_and_lists_them(shell):
    on = disk(dirs=("docs", "docs/old"), docs__a="one\n", top="x")
    assert said(shell, "ls\nls docs\nls /docs/old/\n", on) == (
        "$ ls\ndocs/\n1 top\n$ ls docs\nold/\n4 a\n$ ls /docs/old/\n$ \n"
    )


def test_ls_hides_names_that_start_with_a_dot(shell):
    on = disk(**{".profile": "hidden\n", "shown": ""})
    assert said(shell, "ls\n", on) == "$ ls\n0 shown\n$ \n"


def test_cat_prints_a_file(shell):
    on = disk(notes="line one\nline two\n", empty="")
    assert said(shell, "cat notes\ncat empty\n", on) == (
        "$ cat notes\nline one\nline two\n$ cat empty\n$ \n"
    )


def test_cat_follows_a_path(shell):
    on = disk(dirs=("a", "a/b"), a__b__c="deep down\n")
    assert said(shell, "cat a/b/c\ncat //a//b/../b/./c\n", on) == (
        "$ cat a/b/c\ndeep down\n$ cat //a//b/../b/./c\ndeep down\n$ \n"
    )


def test_cat_reads_a_file_over_several_blocks(shell):
    text = "".join(chr(ord("a") + i % 26) for i in range(2 * PAGE + 5)) + "\n"
    on = disk(6, big=text)
    assert said(shell, "cat big\n", on) == f"$ cat big\n{text}$ \n"


def test_failures_are_said_and_the_shell_goes_on(shell):
    on = disk(dirs=("d",), f="text\n")
    out = said(shell, "cat nope\ncat d\nls f\ncat f/x\nls nope\nrm\n", on)
    assert out == (
        "$ cat nope\nsh: nope: no such file or directory\n"
        "$ cat d\nsh: d: is a directory\n"
        "$ ls f\nsh: f: not a directory\n"
        "$ cat f/x\nsh: f/x: not a directory\n"
        "$ ls nope\nsh: nope: no such file or directory\n"
        "$ rm\nsh: which file?\n$ \n"
    )


def test_a_name_too_long_is_said(shell):
    on = disk(**{"y" * 17: "ok\n"})
    out = said(shell, f"cat {'x' * 18}\ncat {'y' * 17}\n", on)
    assert out == f"$ cat {'x' * 18}\nsh: {'x' * 18}: name too long\n" + (
        f"$ cat {'y' * 17}\nok\n$ \n"
    )


def test_the_shell_does_not_run_out_of_descriptors(shell):
    # Each built-in closes what it opened, failing or not: more than NDESC (9)
    # of them still work.
    on = disk(dirs=("d",), f="x\n")
    out = said(shell, "cat f\nls f\n" * 6 + "cat f\n", on)
    assert out.count("$ cat f\nx\n") == 7


def test_a_disk_without_a_filesystem_is_reported(shell):
    blank = (new_disk(), 3)
    assert said(shell, "ls\n", blank) == (
        "$ ls\nsh: .: no filesystem on the disk\n$ \n"
    )
    assert "sh: x: no filesystem on the disk\n" in said(shell, "cat x\n", None)


def test_write_makes_a_file_the_tool_can_read(shell):
    on = disk()
    out = said(shell, "write motd  welcome to   ternary\ncat motd\n", on)
    assert out == (
        "$ write motd  welcome to   ternary\n$ cat motd\nwelcome to   ternary\n$ \n"
    )
    assert Filesystem.load(on[0]).read("motd") == "welcome to   ternary\n"


def test_write_replaces_a_file_and_frees_what_it_held(shell):
    on = disk(motd="x" * (2 * PAGE))
    said(shell, "write motd new text\n", on)
    made = Filesystem.load(on[0])
    assert made.read("motd") == "new text\n"
    assert len(made.free_blocks()) == 8 - 4  # 0, 1, / and motd's one block


def test_mkdir_rm_and_rmdir(shell):
    on = disk()
    out = said(
        shell,
        "mkdir docs\nwrite docs/a one\nmkdir docs\nrmdir docs\nrm docs\n"
        "ls docs\nrm docs/a\nrmdir docs\nls\nrm nope\n",
        on,
    )
    assert out == (
        "$ mkdir docs\n$ write docs/a one\n"
        "$ mkdir docs\nsh: docs: file exists\n"
        "$ rmdir docs\nsh: docs: directory not empty\n"
        "$ rm docs\nsh: docs: is a directory\n"
        "$ ls docs\n4 a\n$ rm docs/a\n$ rmdir docs\n$ ls\n"
        "$ rm nope\nsh: nope: no such file or directory\n$ \n"
    )
    made = Filesystem.load(on[0])
    assert made.listdir() == []
    assert made.free_blocks() == list(range(3, 8))


def test_a_full_disk_is_said(shell):
    on = disk(4, a="first\n")  # block 3 is the only data block, and a's
    out = said(shell, "write b more\nmkdir d\ncat a\n", on)
    assert "sh: b: no space left\n" in out
    assert "sh: d: no space left\n" in out
    assert out.endswith("$ cat a\nfirst\n$ \n")


def test_cd_pwd_and_relative_paths(shell):
    on = disk(dirs=("docs",), docs__a="in docs\n", top="at the top\n")
    out = said(
        shell,
        "pwd\ncd docs\npwd\nls\ncat a\ncat ../top\nmkdir sub\ncd sub\npwd\n"
        "rmdir /docs/sub\ncd nope\ncd /docs/a\ncd\npwd\nls docs\n",
        on,
    )
    assert out == (
        "$ pwd\n/\n$ cd docs\n$ pwd\n/docs\n$ ls\n8 a\n$ cat a\nin docs\n"
        "$ cat ../top\nat the top\n$ mkdir sub\n$ cd sub\n$ pwd\n/docs/sub\n"
        "$ rmdir /docs/sub\nsh: /docs/sub: busy\n"
        "$ cd nope\nsh: nope: no such file or directory\n"
        "$ cd /docs/a\nsh: /docs/a: not a directory\n"
        "$ cd\n$ pwd\n/\n$ ls docs\n8 a\nsub/\n$ \n"
    )
