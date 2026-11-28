"""bin/vi, the screen editor, driven through the shell. Keys come from
the console's input as a terminal would send them (a CR for Enter, ESC
for Escape, ESC [ A for the up arrow); what the editor drew is ANSI
sequences, so the tests judge it by the file it wrote, its exit code
and the messages on its status line."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tools.fs import Filesystem

ESC = "\x1b"
UP = ESC + "[A"
NOTES = "one\ntwo\nthree\n"


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def edit(shell, typed: str, **texts: str):
    """Run typed through the shell on a disk with texts; the console's
    output after boot, and the filesystem afterwards."""
    disk = bin_disk(**texts)
    result = run_image(shell, input=typed, disk=disk, max_steps=80_000_000)
    assert result.exit_code == 0, result.console
    return result.after_boot, Filesystem.load(disk[0])


def vi_exit(out: str) -> int:
    """The editor's exit code: the first program the shell ran."""
    codes = re.findall(r"process 8 exited with code (-?\d+)", out)
    assert len(codes) == 1, out
    return int(codes[0])


def test_a_new_file_is_written_with_wq(shell):
    out, fs = edit(shell, f"vi new\riline one\rline two{ESC}:wq\rcat new\r")
    assert '"new" [New]' in out
    assert '"new" 2L, 18B written' in out
    assert vi_exit(out) == 0
    assert fs.read("new") == "line one\nline two\n"
    assert "$ cat new\nline one\nline two\n$ " in out


def test_normal_mode_changes(shell):
    # dd takes "one" and p puts it below "two"; x takes the t of
    # "three"; o opens a line below for "four"; A appends to it.
    out, fs = edit(
        shell,
        f"vi notes\rddpjx{ESC}o4{ESC}A!{ESC}:wq\r",
        notes=NOTES,
    )
    assert '"notes" 3L, 14B' in out
    assert vi_exit(out) == 0
    assert fs.read("notes") == "two\none\nhree\n4!\n"


def test_counts_words_and_undo(shell):
    # 2dd takes two lines; u brings them back, and u again takes them
    # once more. G goes to the last line, w to its next word, and D cuts
    # the rest of the line.
    out, fs = edit(
        shell,
        "vi text\r2dduuGwD:x\r",
        text="a b\nc d\nfirst second third\n",
    )
    assert vi_exit(out) == 0
    assert fs.read("text") == "first \n"


def test_quit_refuses_to_lose_changes(shell):
    out, fs = edit(shell, "vi notes\rdd:q\r:q!\rcat notes\r", notes=NOTES)
    assert "No write since last change (add ! to override)" in out
    assert vi_exit(out) == 0
    assert fs.read("notes") == NOTES


def test_insert_mode_keys(shell):
    # An arrow's sequence starts with an escape but leaves insert mode
    # on; Backspace at a line's start joins it to the line before; Enter
    # splits a line.
    out, fs = edit(
        shell,
        f"vi notes\rjA2{UP}1{ESC}jI\x7f-{ESC}$i\r{ESC}:wq\r",
        notes=NOTES,
    )
    assert vi_exit(out) == 0
    assert fs.read("notes") == "one1-two\n2\nthree\n"


def test_command_line_and_writing_elsewhere(shell):
    out, fs = edit(
        shell,
        "vi notes\r:3\rx:w copy\r:nonsense\r:q!\r",
        notes=NOTES,
    )
    assert '"copy" 3L, 13B written' in out
    assert "Not an editor command: nonsense" in out
    assert vi_exit(out) == 0
    assert fs.read("copy") == "one\ntwo\nhree\n"
    assert fs.read("notes") == NOTES


def test_input_ending_with_changes_unwritten(shell):
    out, fs = edit(shell, "vi notes\rdd", notes=NOTES)
    assert "vi: input ended, changes not written" in out
    assert vi_exit(out) == 1
    assert fs.read("notes") == NOTES


def test_usage(shell):
    out, _ = edit(shell, "vi a b\r")
    assert "$ vi a b\nusage: vi [FILE]\n" in out
    assert vi_exit(out) == 2
