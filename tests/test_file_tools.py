"""The everyday file programs of bin/: cp, mv, head, grep and touch. Each
takes its operands as arguments, and head and grep read standard input
when no file is named, so they work in pipes and with redirection. mv is
the file server's rename (tests/test_files_rename.py)."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tools.fs import PAGE, Filesystem

NOTES = "one apple\ntwo pear\nthree apple pie\nfour\n"


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, on=None) -> str:
    """What the shell printed between booting and its exit, without the
    kernel's lines."""
    result = run_image(
        shell, input=typed, disk=on or bin_disk(notes=NOTES), max_steps=10_000_000
    )
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_touch_makes_empty_files_and_leaves_others_alone(shell):
    on = bin_disk(notes=NOTES)
    assert said(shell, "touch a b notes\nls\ntouch\n", on) == (
        "$ touch a b notes\n$ ls\nbin/\n40 notes\n0 a\n0 b\n"
        "$ touch\nusage: touch FILE...\nsh: exit 1\n$ \n"
    )
    assert said(shell, "touch no/a bin\n", on) == (
        "$ touch no/a bin\ntouch: no/a: cannot make\nsh: exit 1\n$ \n"
    )
    Filesystem.load(on[0])  # whole


def test_head_says_the_first_lines_of_files_or_its_input(shell):
    ten = "".join(f"{n}\n" for n in range(1, 13))
    on = bin_disk(notes=NOTES, ten=ten)
    assert said(shell, "head ten\nhead -n 2 notes\nhead -n 0 notes\n", on) == (
        "$ head ten\n" + "".join(f"{n}\n" for n in range(1, 11)) + "$ head -n 2 notes\n"
        "one apple\ntwo pear\n$ head -n 0 notes\n$ \n"
    )
    assert said(shell, "ls bin | head -n 2\nhead -n 1 < notes\n", on) == (
        "$ ls bin | head -n 2\n"
        f"{_size('cp')} cp\n{_size('df')} df\n"
        "$ head -n 1 < notes\none apple\n$ \n"
    )


def _size(name: str) -> int:
    on = bin_disk()
    made = Filesystem.load(on[0])
    return made.inode(made.lookup(f"bin/{name}")).size


def test_head_heads_each_file_by_name_when_there_are_several(shell):
    assert said(shell, "head -n 1 notes nope notes\n") == (
        "$ head -n 1 notes nope notes\n==> notes <==\none apple\n"
        "head: nope: cannot open\n\n==> notes <==\none apple\nsh: exit 1\n$ \n"
    )
    assert said(shell, "head -n x notes\nhead -c 1\n") == (
        "$ head -n x notes\nusage: head [-n N] [FILE]...\nsh: exit 1\n"
        "$ head -c 1\nusage: head [-n N] [FILE]...\nsh: exit 1\n$ \n"
    )


def test_grep_says_the_lines_holding_the_text(shell):
    assert said(shell, "grep apple notes\ngrep -v apple notes\ngrep e notes\n") == (
        "$ grep apple notes\none apple\nthree apple pie\n"
        "$ grep -v apple notes\ntwo pear\nfour\n"
        "$ grep e notes\none apple\ntwo pear\nthree apple pie\n$ \n"
    )


def test_grep_reads_its_input_and_exits_one_when_nothing_matched(shell):
    assert said(shell, "cat notes | grep pie\ngrep kiwi < notes\n") == (
        "$ cat notes | grep pie\nthree apple pie\n$ grep kiwi < notes\nsh: exit 1\n$ \n"
    )


def test_grep_names_the_file_of_each_line_when_there_are_several(shell):
    on = bin_disk(notes=NOTES, more="pie crust\nno newline at the end pie")
    assert said(shell, "grep pie notes more nope\n", on) == (
        "$ grep pie notes more nope\nnotes:three apple pie\nmore:pie crust\n"
        "more:no newline at the end pie\ngrep: nope: cannot open\nsh: exit 2\n$ \n"
    )
    assert said(shell, "grep\ngrep -x a\n", on) == (
        "$ grep\nusage: grep [-v] TEXT [FILE]...\nsh: exit 2\n"
        "$ grep -x a\nusage: grep [-v] TEXT [FILE]...\nsh: exit 2\n$ \n"
    )


def test_cp_copies_a_file_and_into_a_directory(shell):
    big = "".join(chr(ord("a") + n % 26) for n in range(PAGE + 100))
    on = bin_disk(44, notes=NOTES, big=big)
    typed = "cp notes copy\nmkdir d\ncp notes big d\ncp notes copy\nls d\n"
    assert said(shell, typed, on) == (
        f"$ cp notes copy\n$ mkdir d\n$ cp notes big d\n$ cp notes copy\n"
        f"$ ls d\n40 notes\n{len(big)} big\n$ \n"
    )
    made = Filesystem.load(on[0])
    assert made.read("copy") == NOTES
    assert made.read("d/notes") == NOTES
    assert made.read("d/big") == big  # across a block's end


def test_cp_over_a_longer_file_leaves_only_the_copy(shell):
    on = bin_disk(notes=NOTES, long="x" * 100)
    said(shell, "cp notes long\n", on)
    assert Filesystem.load(on[0]).read("long") == NOTES


def test_what_cp_cannot_do_it_says(shell):
    on = bin_disk(notes=NOTES, other="x")
    typed = "cp notes\ncp nope x\ncp bin x\ncp notes /notes\ncp notes other x\n"
    assert said(shell, typed, on) == (
        "$ cp notes\nusage: cp FROM TO, or cp FROM... DIR\nsh: exit 1\n"
        "$ cp nope x\ncp: nope: cannot open\nsh: exit 1\n"
        "$ cp bin x\ncp: bin: is a directory\nsh: exit 1\n"
        "$ cp notes /notes\ncp: notes: is the same file\nsh: exit 1\n"
        "$ cp notes other x\ncp: x: not a directory\nsh: exit 1\n$ \n"
    )
    assert Filesystem.load(on[0]).read("notes") == NOTES


def test_mv_renames_replaces_and_moves_into_directories(shell):
    on = bin_disk(notes=NOTES, old="replaced")
    typed = "mv notes n\nmv n old\nmkdir d\nmkdir e\nmv old e d\ncd d/e\npwd\nls ..\n"
    assert said(shell, typed, on) == (
        "$ mv notes n\n$ mv n old\n$ mkdir d\n$ mkdir e\n$ mv old e d\n"
        "$ cd d/e\n$ pwd\n/d/e\n$ ls ..\n40 old\ne/\n$ \n"
    )
    made = Filesystem.load(on[0])  # checks the moved directory's ..
    assert made.read("d/old") == NOTES


def test_what_mv_cannot_do_it_says(shell):
    on = bin_disk(notes=NOTES)
    typed = "mkdir d\nmv nope x\nmv d d/x\nmv notes bin\nmv notes\nmv notes d x\n"
    assert said(shell, typed, on) == (
        "$ mkdir d\n$ mv nope x\nmv: nope: no such file or directory\nsh: exit 1\n"
        "$ mv d d/x\nmv: d: cannot move there\nsh: exit 1\n"
        "$ mv notes bin\n"  # into bin, as bin/notes
        "$ mv notes\nusage: mv FROM TO, or mv FROM... DIR\nsh: exit 1\n"
        "$ mv notes d x\nmv: x: not a directory\nsh: exit 1\n$ \n"
    )
    made = Filesystem.load(on[0])
    assert made.read("bin/notes") == NOTES
