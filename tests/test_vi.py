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
    """The editor's exit code: the first process to end after the shell
    started it."""
    _, found, after = out.partition("$ vi ")
    assert found, out
    codes = re.findall(r"process \d+ exited with code (-?\d+)", after)
    assert codes, out
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
    # 2dd takes two lines and x the f of "first"; u twice brings them
    # back, a third u has nothing left, and Ctrl-R makes the 2dd again.
    # G goes to the last line, w to its next word, and D cuts the rest
    # of the line.
    out, fs = edit(
        shell,
        "vi text\r2ddxuuu\x12GwD:x\r",
        text="a b\nc d\nfirst second third\n",
    )
    assert "Already at oldest change" in out
    assert vi_exit(out) == 0
    assert fs.read("text") == "first \n"


def test_undoing_every_change_leaves_nothing_to_write(shell):
    out, fs = edit(shell, f"vi notes\rddxiz{ESC}uuu:q\r", notes=NOTES)
    assert "No write since" not in out
    assert vi_exit(out) == 0
    assert fs.read("notes") == NOTES


def test_operators_with_motions(shell):
    # dw takes a word; cw changes one, not the blank after it; d$ cuts to
    # the line's end; 2dw two words; de to a word's end; cc a whole line.
    out, fs = edit(
        shell,
        f"vi t\rdwcwB{ESC}wd$j02dwjdejcc7{ESC}:wq\r",
        t="alpha beta gamma delta\none two three\nfour five six\nseven\n",
    )
    assert vi_exit(out) == 0
    assert fs.read("t") == "B \nthree\n five six\n7\n"


def test_yank_put_and_repeat(shell):
    # yw copies a word and P puts it before the cursor; dw and . take
    # two words; xp swaps two characters.
    out, fs = edit(
        shell,
        "vi t\rywjPk0dw.Gxp:wq\r",
        t="one two three\nx\nab\n",
    )
    assert vi_exit(out) == 0
    assert fs.read("t") == "three\none x\nba\n"


def test_repeat_an_insert(shell):
    out, fs = edit(shell, f"vi notes\rA!{ESC}j.j.gg~:wq\r", notes=NOTES)
    assert vi_exit(out) == 0
    assert fs.read("notes") == "One!\ntwo!\nthree!\n"


def test_finding_characters_and_brackets(shell):
    # % goes to the bracket that matches; f and F find a character, ;
    # finds it again and , the other way; ct changes up to one.
    out, fs = edit(
        shell,
        f"vi t\rf(%xj0f,;Dj0f-;,xj0ctoX{ESC}:wq\r",
        t="call(a, (b), c) end\na,b,c,d\nx-y-z\none two\n",
    )
    assert vi_exit(out) == 0
    assert fs.read("t") == "call(a, (b), c end\na,b\nxy-z\nXo\n"


def test_search(shell):
    # /ban finds the next banana and n the one after, then round to the
    # first again; ? searches backwards; d/split deletes up to a match;
    # a pattern ending in $ matches only at a line's end.
    out, fs = edit(
        shell,
        "vi t\r/ban\rnnx?err\rD/zzz\rd/split\rgg/a$\rx:wq\r",
        t="apple\nbanana\ncherry\nbanana split\n",
    )
    assert "search hit BOTTOM, continuing at TOP" in out
    assert "Pattern not found: zzz" in out
    assert vi_exit(out) == 0
    assert fs.read("t") == "apple\nanan\ncsplit\n"


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
