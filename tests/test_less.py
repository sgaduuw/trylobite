"""bin/less, the pager, driven through the shell on a console of a known
size (detrytus --console-size). Keys come from the console's input as a
terminal sends them; what the pager drew is ANSI sequences, a whole
screen each time, so the tests split the output into those screens and
read their rows. Every key draws a screen, a digit of a count too."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image

NUMBERS = "".join(f"line {i}\n" for i in range(1, 31))
SIZE = (10, 40)  # rows, columns: 9 rows of text and the status line


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str, size=SIZE, **texts: str) -> str:
    result = run_image(
        shell,
        input=typed,
        disk=bin_disk(numbers=NUMBERS, **texts),
        console_size=size,
        max_steps=60_000_000,
    )
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def screens(out: str) -> list[list[str]]:
    """Each screen the pager drew, as its rows, without the sequences."""
    frames = out.split("\x1b[?25l\x1b[H")[1:]
    shown = []
    for frame in frames:
        frame = frame.split("\x1b[?25h")[0]
        plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", frame)
        shown.append(plain.replace("\r", "").split("\n"))
    return shown


def test_paging_through_a_file(shell):
    out = session(shell, "less numbers\r Gg5jq")
    first, down, end, top, _, five = screens(out)
    assert first == [f"line {i}" for i in range(1, 10)] + ["numbers"]
    assert down == [f"line {i}" for i in range(10, 19)] + [":"]
    assert end == [f"line {i}" for i in range(22, 31)] + ["(END)"]
    assert top == first
    assert five[0] == "line 6"
    assert out.rstrip().endswith("$")  # back at the shell's prompt
    assert "sh: exit" not in out


def test_counts_and_going_to_a_line(shell):
    out = session(shell, "less numbers\r12g3kGkq")
    _, _, _, twelve, _, nine, end, up = screens(out)
    assert twelve[0] == "line 12"
    assert nine[0] == "line 9"
    assert end[-1] == "(END)"
    assert up[0] == "line 21" and up[-1] == ":"


def test_searching_shows_and_marks_matches(shell):
    out = session(shell, "less numbers\r/line 2\rnn?ine 1\rNq")
    # The screens drawn while a search is typed say it on the last row.
    typing = [s for s in screens(out) if s[-1][:1] in "/?"]
    assert typing[6][-1] == "/line 2"
    shown = [s for s in screens(out) if s[-1][:1] not in "/?"]
    found, again, third, back, forward = shown[1:]
    # The search starts after the first row's line: line 2 is next.
    assert found[0] == "line 2"
    assert again[0] == "line 20"
    assert third[0] == "line 21"
    assert back[0] == "line 19"
    # No line after 19 holds "ine 1".
    assert forward[0] == "line 19" and forward[-1] == "Pattern not found"
    assert "\x1b[7mline 2\x1b[27m" in out


def test_a_search_that_finds_nothing_says_so(shell):
    out = session(shell, "less numbers\r/zebra\rq")
    assert screens(out)[-1][-1] == "Pattern not found"


def test_long_lines_wrap_and_tabs_expand(shell):
    long = "x" * 90 + "\n" + "a\tb\x01c\n"
    out = session(shell, "less long\rq", long=long)
    first = screens(out)[0]
    assert first[:4] == ["x" * 40, "x" * 40, "x" * 10, "a       b^Ac"]
    assert first[4] == "~"
    assert first[-1] == "(END)"


def test_less_reads_a_pipe_and_takes_keys_from_the_console(shell):
    out = session(shell, "cat numbers | less\rGq\recho after\r")
    first, end = screens(out)
    assert first[0] == "line 1" and first[-1] == ":"  # no name for a pipe
    assert end[-1] == "(END)"
    assert "$ echo after\nafter\n" in out


def test_without_a_console_less_copies(shell):
    out = session(shell, "less numbers | wc\rless nothing\rless\r")
    assert "$ less numbers | wc\n30 60 231\n" in out
    assert "less: nothing: no such file or directory\nsh: exit 1\n" in out
    assert "$ less\nless: missing filename\nsh: exit 1\n" in out
