"""The shell build: sh reads lines, runs programs, from the kernel image
or the disk, and reports how they ended."""

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, new_disk, run_image


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str, disk=None):
    """Run the shell on typed, with bin/ on its disk unless given another."""
    result = run_image(shell, input=typed, disk=disk or bin_disk())
    assert result.exit_code == 0, result.console
    return result


def test_a_session_runs_programs_and_reports_how_they_ended(shell):
    # Init is process 0; 1 to 4 are the console, pipe, disk and file
    # servers, which it starts first, and 5 is the shell.
    result = session(shell, "hello\nfail\nnope\nexit\n")
    transcript, _ = result.after_boot.rsplit(" timer interrupts", 1)
    assert transcript.rsplit(" ", 1)[0] == (
        "$ hello\n"
        "hello from a balanced-ternary machine\n"
        "trylobite: process 6 exited with code 0\n"
        "$ fail\n"
        "trylobite: process 7 exited with code 3\n"
        "sh: exit 3\n"
        "$ nope\n"
        "sh: no such program: nope\n"
        "$ exit\n"
        "trylobite: process 5 exited with code 0\n"
        "trylobite: process 0 exited with code 0\n"
        "trylobite: all processes exited after"
    )


def test_backspace_and_delete_erase_what_was_typed(shell):
    result = session(shell, "hellp\bo\nfaij\x7fl\n")
    assert "$ hellp\b \bo\nhello from" in result.console
    assert "sh: exit 3\n" in result.console
    # Erasing past the start of the line erases nothing.
    assert "sh: no such program" not in session(shell, "\b\bhello\n").console


def test_only_the_first_word_counts_and_blank_lines_are_skipped(shell):
    result = session(shell, "\n   \n  hello there\n")
    assert result.console.count("$ ") == 4  # three lines, then end of input
    assert "hello from a balanced-ternary machine" in result.console


def test_a_long_line_keeps_its_first_sixty_characters(shell):
    result = session(shell, "x" * 70 + "\n")
    assert f"sh: no such program: {'x' * 60}\n" in result.console


def test_pingpong_comes_back_to_the_prompt_once_both_are_done(shell):
    result = session(shell, "pingpong\n")
    console = result.console
    assert [f"pong: got {n}" in console for n in (1, 2, 3)] == [True] * 3
    last_pong = console.index("pong: got 3")
    assert console.index("$ ", console.index("$ pingpong") + 2) > last_pong


def test_the_shell_exits_at_the_end_of_input(shell):
    result = session(shell, "hello")  # no newline: the line is never run
    assert "hello from" not in result.console
    assert result.code_of(0) == 0


def test_programs_come_from_the_disk(shell):
    # Only pingpong is in the kernel image; hello is a file, and without
    # it, or without a filesystem at all, there is no such program.
    assert "hello from" in session(shell, "hello\n").console
    blank = (new_disk(), 4)
    assert "sh: no such program: hello\n" in session(shell, "hello\n", blank).console


def test_a_text_file_is_not_a_program(shell):
    result = session(shell, "/notes\nhello\n", bin_disk(notes="li a0, 4\n", empty=""))
    assert "$ /notes\nsh: not a program: /notes\n$ hello\nhello from" in result.console
    result = session(shell, "/empty\n/bin\n", bin_disk(empty=""))
    assert "sh: not a program: /empty\n" in result.console
    assert "sh: not a program: /bin\n" in result.console  # nor is a directory


def test_a_word_without_a_slash_is_looked_for_in_bin(shell):
    result = session(shell, "notes\n/bin/hello\n", bin_disk(notes="li a0, 4\n"))
    assert "$ notes\nsh: no such program: notes\n" in result.console
    assert "$ /bin/hello\nhello from" in result.console


def test_ls_lists_the_programs_on_the_disk(shell):
    result = session(shell, "ls bin\nfail\n")
    assert "sh: exit 3\n" in result.console
    listed = result.after_boot.splitlines()[1:23]
    assert [line.split()[1] for line in listed] == [
        "cp",
        "df",
        "dmesg",
        "echo",
        "fail",
        "free",
        "grep",
        "head",
        "hello",
        "kill",
        "mv",
        "ps",
        "recho",
        "rhello",
        "sleep",
        "spin",
        "top",
        "touch",
        "uname",
        "upper",
        "uptime",
        "wc",
    ]
