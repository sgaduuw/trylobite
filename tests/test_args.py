"""Program arguments: spawnw copies a block of strings from the parent's
memory into the lower half of the child's page and starts the child with
a0 = how many and a1 = V_ARGV, a word per argument holding its address
and then a 0 word (include/layout.s, ARG_MAX). The file server's spawnf
passes its caller's on, and the shell gives a program the words of its
command line, the command first."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tests.test_spawnw import disk_with, program, run, start_from
from tools.fs import program_file

E_INVAL = -10  # include/layout.s
E_FAULT = -12

# Says each argument between bars, checks the list ends with a 0 word,
# and exits with how many there are.
SHOW = program("""
        mv    s0, a0
        mv    s1, a1
        li    t0, V_ARGV
        bne   s1, t0, 9f
1:      lw    a1, 0(s1)
        beqz  a1, 2f
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_PUTS
        la    a1, bar
        sys
        addi  s1, s1, 3
        j     1b
2:      li    t0, 3                    # the 0 word comes after argc words
        mul   t0, s0, t0
        li    t1, V_ARGV
        add   t0, t0, t1
        bne   t0, s1, 9f
        li    a0, SYS_EXIT
        mv    a1, s0
        sys
9:      li    a0, SYS_EXIT
        li    a1, 99
        sys
bar:    .string "|"
""")


def start_with(block: int, args: str, n: str) -> str:
    """start_from, with an argument block labelled args after the code."""
    return start_from(block, args="args", n=n) + f"\nargs:  {args}\n"


def shown(result) -> str:
    return re.sub(r"trylobite: [^\n]*\n", "", result.console)


@pytest.fixture(scope="module")
def show_disk():
    return disk_with(show=program_file(SHOW))


def test_a_child_gets_its_arguments_as_argc_and_argv(show_disk):
    disk, first = show_disk
    block = '.string "wc"\n       .string "notes"\n       .string "x"'
    code = start_with(first["show"], block, "11")
    result = run(code, disk=disk)
    assert result.code_of(0) == 3
    assert shown(result) == "wc|notes|x|"


def test_empty_strings_count_and_the_last_may_end_at_the_block_end(show_disk):
    disk, first = show_disk
    # a, "" and b: the last has no 0 of its own, and the 0 after it is the
    # child's page's, not the c that follows in the parent's memory.
    code = start_with(first["show"], ".tryte 'a', 0, 0, 'b', 'c'", "4")
    result = run(code, disk=disk)
    assert result.code_of(0) == 3
    assert shown(result) == "a||b|"


def test_no_arguments_is_argc_zero(show_disk):
    disk, first = show_disk
    result = run(start_from(first["show"]), disk=disk)
    assert result.code_of(0) == 0
    assert shown(result) == ""


def test_the_block_is_checked_before_anything_starts(show_disk):
    disk, first = show_disk
    # The longest block is fine, one tryte more is not, nor a negative
    # count, nor a block reaching past the parent's memory.
    full = start_with(first["show"], ".zero ARG_MAX", "ARG_MAX")
    assert run(full, disk=disk).code_of(0) == 243  # 243 empty strings
    big = start_with(first["show"], ".zero ARG_MAX + 1", "ARG_MAX + 1")
    assert run(big, disk=disk).code_of(0) == E_INVAL
    negative = start_with(first["show"], ".zero 1", "-1")
    assert run(negative, disk=disk).code_of(0) == E_INVAL
    outside = start_from(first["show"], args="V_USER + 9841", n="2")
    assert run(outside, disk=disk).code_of(0) == E_FAULT
    nowhere = start_from(first["show"], args="V_USER - PAGE", n="1")
    assert run(nowhere, disk=disk).code_of(0) == E_FAULT


# --- the shell -----------------------------------------------------------------


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, on=None) -> str:
    result = run_image(shell, input=typed, disk=on or bin_disk(), max_steps=20_000_000)
    assert result.exit_code == 0, result.console
    console = result.after_boot
    return re.sub(r"trylobite: [^\n]*\n", "", console)


def test_echo_says_its_arguments(shell):
    assert said(shell, "echo  hello   ternary world \necho\n") == (
        "$ echo  hello   ternary world \nhello ternary world\n$ echo\n\n$ \n"
    )


def test_redirections_are_not_arguments(shell):
    assert said(shell, "echo a >out b\ncat out\necho in < out c\n") == (
        "$ echo a >out b\n$ cat out\na b\n$ echo in < out c\nin c\n$ \n"
    )


def test_wc_counts_the_files_it_is_given(shell):
    on = bin_disk(notes="quiet words\n", more="one\ntwo three\n")
    assert said(shell, "wc notes\nwc notes more\n", on) == (
        "$ wc notes\n1 2 12 notes\n"
        "$ wc notes more\n1 2 12 notes\n2 3 14 more\n3 5 26 total\n$ \n"
    )


def test_wc_says_which_file_it_cannot_open(shell):
    on = bin_disk(notes="quiet words\n")
    assert said(shell, "wc nope notes\n", on) == (
        "$ wc nope notes\nwc: nope: no such file or directory\n1 2 12 notes\n"
        "1 2 12 total\nsh: exit 1\n$ \n"
    )


def test_arguments_reach_each_program_of_a_pipeline(shell):
    on = bin_disk(notes="quiet words\n")
    assert said(shell, "echo x y | wc\nwc notes | upper\n", on) == (
        "$ echo x y | wc\n1 2 4\n$ wc notes | upper\n1 2 12 NOTES\n$ \n"
    )


def test_a_path_command_is_argv_zero_as_typed(shell):
    assert said(shell, "/bin/echo hi\n") == "$ /bin/echo hi\nhi\n$ \n"
