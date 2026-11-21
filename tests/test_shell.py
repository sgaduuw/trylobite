"""The shell build: sh reads lines, runs programs, and reports how they
ended."""

import pytest

from tests.kernel import ROOT, assemble_file, run_image


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str):
    result = run_image(shell, input=typed)
    assert result.exit_code == 0, result.console
    return result


def test_a_session_runs_programs_and_reports_how_they_ended(shell):
    result = session(shell, "hello\nfail\nnope\nexit\n")
    transcript, _ = result.console.rsplit(" timer interrupts", 1)
    assert transcript.rsplit(" ", 1)[0] == (
        "trylobite: booting\n"
        "$ hello\n"
        "hello from a balanced-ternary machine\n"
        "trylobite: process 1 exited with code 0\n"
        "$ fail\n"
        "trylobite: process 2 exited with code 3\n"
        "sh: exit 3\n"
        "$ nope\n"
        "sh: no such program: nope\n"
        "$ exit\n"
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
