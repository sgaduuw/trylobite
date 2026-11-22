"""The shell's redirections: < PATH, > PATH and >> PATH after a command
point its standard input or output at a file for that command alone,
built-in or program; the shell's own complaints go to standard error,
the console, whatever is redirected."""

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tools.fs import Filesystem


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, on) -> str:
    """What the shell printed between booting and its exit."""
    result = run_image(shell, input=typed, disk=on, max_steps=5_000_000)
    assert result.exit_code == 0, result.console
    console = result.console.removeprefix("trylobite: booting\n")
    console = "".join(
        line
        for line in console.splitlines(keepends=True)
        if not line.startswith("trylobite: process ")
    )
    return console.split("trylobite: all processes")[0]


def test_output_goes_to_the_file_and_comes_back_after(shell):
    on = bin_disk(12)
    out = said(shell, "pwd > p\npwd\nhello >out\ncat out\n", on)
    assert out == (
        "$ pwd > p\n$ pwd\n/\n$ hello >out\n"
        "$ cat out\nhello from a balanced-ternary machine\n$ \n"
    )
    made = Filesystem.load(on[0])
    assert made.read("p") == "/\n"
    assert made.read("out") == "hello from a balanced-ternary machine\n"


def test_output_replaces_with_one_arrow_and_adds_with_two(shell):
    on = bin_disk(12, notes="old text that is long\n")
    said(shell, "pwd > notes\nhello >> notes\npwd >>notes\n", on)
    assert Filesystem.load(on[0]).read("notes") == (
        "/\nhello from a balanced-ternary machine\n/\n"
    )


def test_input_comes_from_the_file(shell):
    on = bin_disk(12, notes="one\ntwo\n")
    out = said(shell, "cat < notes\ncat <notes >copy\ncat copy\n", on)
    assert out == (
        "$ cat < notes\none\ntwo\n$ cat <notes >copy\n$ cat copy\none\ntwo\n$ \n"
    )


def test_a_redirection_comes_out_of_the_words_wherever_it_is(shell):
    on = bin_disk(12)
    said(shell, "write >w a  b > x c\n", on)
    made = Filesystem.load(on[0])
    # write's file is its first word left, a, and the text follows as typed
    assert made.read("a") == "b c\n"
    assert made.read("w") == "" and made.read("x") == ""


def test_complaints_reach_the_console_and_the_file_stays_empty(shell):
    on = bin_disk(12)
    out = said(shell, "cat nope > out\nfail > out2\ncat < nope\nls >\nls >>  \n", on)
    assert out == (
        "$ cat nope > out\nsh: nope: no such file or directory\n"
        "$ fail > out2\nsh: exit 3\n"
        "$ cat < nope\nsh: nope: no such file or directory\n"
        "$ ls >\nsh: which file?\n"
        "$ ls >>  \nsh: which file?\n$ \n"
    )
    made = Filesystem.load(on[0])
    assert made.read("out") == "" and made.read("out2") == ""


def test_redirected_files_are_closed_each_time(shell):
    # More redirections than the file server keeps files open (NFILE):
    # each command's file closes at the next prompt.
    on = bin_disk(12)
    out = said(shell, "pwd >> p\n" * 30 + "cat p\n", on)
    assert out.endswith("$ cat p\n" + "/\n" * 30 + "$ \n")
