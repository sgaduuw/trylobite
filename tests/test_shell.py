"""The shell build: sh reads lines, runs programs, from the kernel image
or the disk, and reports how they ended."""

import pytest

from tests.kernel import (
    ROOT,
    assemble_file,
    bin_disk,
    new_disk,
    run_image,
    shell_filesystem,
)


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str, disk=None, max_steps=None):
    """Run the shell on typed, with bin/ on its disk unless given another."""
    more = {} if max_steps is None else {"max_steps": max_steps}
    result = run_image(shell, input=typed, disk=disk or bin_disk(), **more)
    assert result.exit_code == 0, result.console
    return result


def test_a_session_runs_programs_and_reports_how_they_ended(shell):
    # Init is process 0; 1 to 4 are the console, pipe, disk and file
    # servers, which it starts first, and 5 is the shell.
    result = session(shell, "hello\nfail\nnope\nexit 0\n")
    transcript, _ = result.after_boot.rsplit(" timer interrupts", 1)
    assert transcript.rsplit(" ", 1)[0] == (
        "$ hello\n"
        "hello from a balanced-ternary machine\n"
        "trylobite: process 8 exited with code 0\n"
        "$ fail\n"
        "trylobite: process 9 exited with code 3\n"
        "sh: exit 3\n"
        "$ nope\n"
        "sh: no such program: nope\n"
        "$ exit 0\n"
        "trylobite: process 7 exited with code 0\n"
        "trylobite: process 0 exited with code 0\n"
        "trylobite: all processes exited after"
    )


def test_exit_without_a_code_exits_with_the_last_status(shell):
    result = run_image(shell, input="fail\nexit\n", disk=bin_disk())
    assert result.code_of(7) == 3


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


def test_a_carriage_return_ends_a_line_and_control_characters_are_dropped(shell):
    # A terminal's Enter may send CR, or CR LF: either ends one line, so
    # neither leaves a stray empty command behind.
    # (Ctrl-R, \x12, is not an editing key: tests/test_shell_editing.py.)
    result = session(shell, "\r\n\rhel\x12lo\r\nhello\rexit\n")
    assert "no such program" not in result.console
    assert result.console.count("hello from a balanced-ternary machine") == 2


def test_escape_sequences_leave_nothing_in_the_line(shell):
    # Up arrow (ESC [ A, or ESC O A in application mode) with no history,
    # Delete (ESC [ 3 ~) at the end of the line, Alt+x (ESC x) and
    # Ctrl+Right (ESC [ 1 ; 5 C) at the end leave nothing in the line.
    result = session(shell, "\x1b[A\n\x1bOAhe\x1b[3~l\x1bxlo\x1b[1;5C\n")
    assert "no such program" not in result.console
    assert "\x1b" not in result.after_boot
    assert "hello from a balanced-ternary machine" in result.console


def test_a_long_line_keeps_its_first_240_characters(shell):
    result = session(shell, "x" * 250 + "\n", max_steps=20_000_000)
    assert f"sh: no such program: {'x' * 240}\n" in result.console


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
    # it there is no such program. The shell itself is /bin/sh.
    assert "hello from" in session(shell, "hello\n").console
    bare, _ = shell_filesystem(12)
    bare.save(path := new_disk())
    result = session(shell, "hello\npingpong\n", (path, 12))
    assert "sh: no such program: hello\n" in result.console
    assert "pong: got 3" in result.console


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
    # Forty programs, some of two blocks, take a while to list.
    result = session(shell, "ls bin\nfail\n", max_steps=12_000_000)
    assert "sh: exit 3\n" in result.console
    listed = result.after_boot.splitlines()[1:41]
    assert [line.split()[1] for line in listed] == [
        "cp",
        "date",
        "df",
        "dmesg",
        "echo",
        "fail",
        "fetch",
        "free",
        "grep",
        "head",
        "hello",
        "host",
        "httpd",
        "ifconfig",
        "kill",
        "mv",
        "nc",
        "ntpctl",
        "ntpd",
        "ping",
        "printenv",
        "ps",
        "rfact",
        "rmandel",
        "rsort",
        "rsqrt",
        "rthreads",
        "sh",
        "sleep",
        "spin",
        "stty",
        "tee",
        "top",
        "touch",
        "uname",
        "upper",
        "uptime",
        "vi",
        "wc",
        "xargs",
    ]
