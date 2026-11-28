"""The shell's pipelines: a | b runs a and b side by side, a's standard
output a pipe (user/piped.s) that is b's standard input. bin/upper and
bin/wc are filters to pipe into; a built-in may take one place in a
pipeline."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, on=None) -> str:
    """What the shell printed between booting and its exit, without the
    kernel's lines."""
    # 15 pipelines take about 12 million steps with the descriptor calls
    # in Rust (8.3 million in assembly), before the port's speed pass.
    result = run_image(shell, input=typed, disk=on or bin_disk(), max_steps=15_000_000)
    assert result.exit_code == 0, result.console
    console = result.after_boot
    return re.sub(r"trylobite: [^\n]*\n", "", console)


HELLO = "hello from a balanced-ternary machine\n"


def test_programs_pipe_into_each_other(shell):
    assert said(shell, "hello | upper\nhello|upper|wc\n") == (
        f"$ hello | upper\n{HELLO.upper()}$ hello|upper|wc\n1 5 38\n$ \n"
    )


def test_a_built_in_can_write_into_a_pipe_or_read_from_one(shell):
    on = bin_disk(notes="one two\nthree\n")
    assert said(shell, "cat notes | wc\nhello | cat\nls | upper\n", on) == (
        f"$ cat notes | wc\n2 3 14\n$ hello | cat\n{HELLO}"
        "$ ls | upper\nBIN/\n14 NOTES\n$ \n"
    )


def test_a_pipe_carries_more_than_it_holds(shell):
    # 3,640 code points, five times what a pipe holds, through three
    # programs and a built-in.
    big = ("abcdefghij" * 9 + "\n") * 40
    on = bin_disk(big=big)
    assert said(shell, "cat big | upper | upper | wc\n", on) == (
        "$ cat big | upper | upper | wc\n40 40 3640\n$ \n"
    )


def test_redirections_mix_with_pipes(shell):
    on = bin_disk(notes="quiet words\n")
    out = said(
        shell, "upper < notes | wc > count\ncat count\nhello | upper > up\ncat up\n", on
    )
    assert out == (
        "$ upper < notes | wc > count\n$ cat count\n1 2 12\n"
        f"$ hello | upper > up\n$ cat up\n{HELLO.upper()}$ \n"
    )


def test_each_program_says_how_it_ended(shell):
    out = said(shell, "hello | fail\nfail | wc\n")
    first, second = out.split("$ fail | wc\n")
    assert first == "$ hello | fail\nsh: exit 3\n"
    # wc's count and the shell's word on fail may come in either order, and
    # wc's one write can even land between the shell's parts of its line
    assert "0 0 0\n" in second
    assert second.replace("0 0 0\n", "", 1) == "sh: exit 3\n$ \n"


def test_what_a_pipeline_cannot_do_is_said(shell):
    # "pwd |", not "hello |": the shell starts hello before it finds the
    # end missing, and on several harts the kernel's line for hello's exit
    # can land in the middle of the complaint.
    out = said(shell, "| hello\npwd |\nls | cat\na | b | c | d | e\nhello | nope\n")
    assert out == (
        "$ | hello\nsh: a command is missing around |\n"
        "$ pwd |\nsh: a command is missing around |\n"
        "$ ls | cat\nsh: one built-in to a pipeline\n"
        "$ a | b | c | d | e\nsh: no such program: a\n"
        "$ hello | nope\nsh: no such program: nope\n$ \n"
    )


def test_ctrl_c_ends_a_pipeline_one_program_at_a_time(shell):
    # spin never ends: Ctrl-C kills it, and wc then sees its pipe end.
    out = said(shell, "spin | wc\n\x03hello\n")
    assert out.startswith("$ spin | wc\n")
    assert "0 0 0\n" in out and "sh: killed" in out
    assert out.endswith(f"$ hello\n{HELLO}$ \n")


def test_pipelines_leave_nothing_open(shell):
    # More pipelines than the pipe server has pipes, and than the shell
    # has descriptors.
    out = said(shell, "hello | upper | wc\n" * 15)
    assert out.count("1 5 38\n") == 15
