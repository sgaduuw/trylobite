"""The shell's line editor: the cursor keys and mid-line editing, the
Ctrl keys of a Unix shell, the history, and Tab completion of commands
and paths. A terminal follows the line with backspaces, which move left,
and characters printed over what is there."""

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk
from tests.test_args import said

UP, DOWN, RIGHT, LEFT = "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D"
HOME, END, DELETE = "\x1b[H", "\x1b[F", "\x1b[3~"
CTRL = {key: chr(ord(key) - ord("a") + 1) for key in "abefklnpuw"}
BEL = "\x07"


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def outputs(shell, typed: str, on=None) -> list[str]:
    """What each typed line printed after its echo, the prompts left out."""
    return [part.split("\n", 1)[1] for part in said(shell, typed, on).split("$ ")[1:-1]]


def test_typing_in_the_middle_of_the_line_prints_its_tail_again(shell):
    # e, h, o: Home, right over the e, then c goes in before the h; Enter
    # prints the rest, so the cursor ends the line.
    typed = f"eho hi{HOME}{RIGHT}c\n"
    assert said(shell, typed) == (
        "$ eho hi" + "\b" * 6 + "e" + "cho hi" + "\b" * 5 + "ho hi\nhi\n$ \n"
    )


def test_left_right_home_and_end_and_their_ctrl_keys(shell):
    a, b, e, f = CTRL["a"], CTRL["b"], CTRL["e"], CTRL["f"]
    assert outputs(
        shell,
        f"eho a{LEFT * 4}c{END} b\n"
        f"cho x{a}e{e}y{b}{b}{f}z\n"
        # Home and End as ESC [ 1 ~ and ESC [ 4 ~, and in application mode.
        f"cho 1\x1b[1~e\x1b[4~2\x1bOH\x1bOF3\n",
    ) == ["a b\n", "xzy\n", "123\n"]


def test_backspace_and_delete_in_the_middle(shell):
    typed = f"echo hxi{LEFT}\b\necho hxi{LEFT * 2}{DELETE}\n"
    assert outputs(shell, typed) == ["hi\n"] * 2
    # Erasing closes the line up and blanks the tryte it left behind.
    assert said(shell, f"echo hxi{LEFT}\b\n").startswith("$ echo hxi\b\bi \b\bi\n")


def test_ctrl_u_k_and_w_erase_the_start_the_end_and_a_word(shell):
    u, k, w = CTRL["u"], CTRL["k"], CTRL["w"]
    assert outputs(
        shell,
        f"junk{u}echo a\n"
        f"echo b there{LEFT * 6}{k}\n"
        f"echo c two  {w}three\n"
        f"echo d e{LEFT}{w}\n",
    ) == ["a\n", "b\n", "c three\n", "e\n"]


def test_up_and_down_go_through_the_lines_typed(shell):
    p, n = CTRL["p"], CTRL["n"]
    assert outputs(
        shell,
        f"echo one\necho two\n{UP}{UP}\n{p}{p}{n}\n"
        # Down past the newest gives back the line being typed.
        f"echo draft{UP}{UP}{DOWN}{DOWN}\n"
        # A shorter line replaces a longer one, blanking the rest.
        f"echo a long line\necho s\n{UP}{UP}{DOWN}\n",
    ) == ["one\n", "two\n", "one\n", "one\n", "draft\n", "a long line\n", "s\n", "s\n"]
    out = said(shell, f"echo four\necho 4{UP}{UP}\n")
    assert "$ echo 4\b\b\b\b\b\becho four\nfour\n" in out


def test_the_history_keeps_sixteen_lines_and_no_repeats(shell):
    typed = "".join(f"echo {i}\n" for i in range(17)) + UP * 20 + "\n"
    assert outputs(shell, typed)[-1] == "1\n"
    # The same line twice is kept once, and an empty one not at all.
    assert outputs(shell, f"echo x\necho x\n\necho y\n{UP * 3}\n")[-1] == "x\n"


def test_tab_completes_commands_built_ins_and_paths(shell):
    on = bin_disk(notes="a note\n")
    assert outputs(shell, "ech\thi\npw\t\ncat no\t\n", on) == [
        "hi\n",
        "/\n",
        "a note\n",
    ]
    assert said(shell, "ech\thi\n").startswith("$ echo hi\n")


def test_tab_completes_a_directory_with_a_slash_and_reads_into_it(shell):
    typed = "mkdir docs\nwrite docs/a one\ncat do\ta\t\nls /b\the\t\t\n"
    out = said(shell, typed)
    assert "$ cat docs/a \none\n" in out
    assert f"$ ls /bin/he{BEL}\nhead    hello\n$ ls /bin/he\n" in out


def test_several_names_complete_as_far_as_they_share_then_list(shell):
    on = bin_disk(notes1="1\n", notes2="2\n", other="3\n")
    out = said(shell, "cat n\t\t\t1\n", on)
    # The first Tab adds what both share, the second rings the bell, the
    # third lists them and prints the line again. A column leaves room
    # for a directory's slash.
    assert out.startswith(f"$ cat notes{BEL}\nnotes1   notes2\n$ cat notes1\n1\n")


def test_a_second_tab_lists_commands_in_columns(shell):
    out = said(shell, "u\t\t\b\b\n")
    assert out.startswith(f"$ u{BEL}\nuname   upper   uptime\n$ u\b \b\n")


def test_nothing_to_complete_rings_the_bell(shell):
    assert said(shell, "zz\t\t\n").startswith(f"$ zz{BEL}{BEL}\n")


def test_names_with_a_leading_dot_complete_only_when_asked(shell):
    on = bin_disk(**{".hidden": "secret\n", "seen": "shown\n"})
    out = said(shell, "cat \t\t\b\b\b\b\ncat .\t\n", on)
    assert f"$ cat {BEL}\nbin/   seen\n$ cat " in out
    assert "$ cat .hidden \nsecret\n" in out


def test_ctrl_l_clears_the_screen_and_prints_the_line_again(shell):
    out = said(shell, f"echo hi{LEFT}{CTRL['l']}\n")
    assert out.startswith("$ echo hi\b\x1b[H\x1b[2J$ echo hi\bi\nhi\n")
