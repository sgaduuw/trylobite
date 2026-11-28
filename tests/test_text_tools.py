"""sort and diff of bin/, run from the shell on a disk of bin/. sort
reads every line before it writes, so `sort -o f f` is safe; diff's
output is checked against what Unix's diff says for the same files."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tools.fs import Filesystem

FRUIT = "pear 3\napple 10\nfig 2\nApple 7\npear 3\nbanana -1\n"
TABLE = "b:2:x\na:10:y\nc:1:x\n"


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, on=None, max_steps: int = 40_000_000) -> str:
    """What the shell printed between booting and its exit, without the
    kernel's lines."""
    result = run_image(
        shell,
        input=typed,
        disk=on or bin_disk(fruit=FRUIT, table=TABLE),
        max_steps=max_steps,
    )
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def output(shell, command: str, on=None) -> str:
    """What one command printed: the lines between it and the next prompt."""
    out = said(shell, command + "\n", on)
    _, _, rest = out.partition(f"$ {command}\n")
    return rest.removesuffix("$ \n")


# --- sort -----------------------------------------------------------------------


def test_sort_orders_by_code_point_and_keeps_every_line(shell):
    assert output(shell, "sort fruit") == (
        "Apple 7\napple 10\nbanana -1\nfig 2\npear 3\npear 3\n"
    )


def test_sort_options(shell):
    assert output(shell, "sort -r -u fruit") == (
        "pear 3\nfig 2\nbanana -1\napple 10\nApple 7\n"
    )
    # Folded, "apple 10" comes before "Apple 7": 1 before 7.
    assert output(shell, "sort -f fruit") == (
        "apple 10\nApple 7\nbanana -1\nfig 2\npear 3\npear 3\n"
    )
    # -k2 -n: by the second field's number; -1 first, 10 last.
    assert output(shell, "sort -n -k 2 fruit") == (
        "banana -1\nfig 2\npear 3\npear 3\nApple 7\napple 10\n"
    )
    assert output(shell, "sort -t: -k2,2n table") == "c:1:x\nb:2:x\na:10:y\n"
    # -u by a key keeps the first line of each key, in input order.
    assert output(shell, "sort -t : -u -k3 table") == "b:2:x\na:10:y\n"


def test_sort_is_a_filter_and_sorts_in_place(shell):
    on = bin_disk(fruit=FRUIT, table=TABLE)
    out = said(shell, "cat table | sort\nsort -o table table\ncat table\n", on)
    assert out == (
        "$ cat table | sort\na:10:y\nb:2:x\nc:1:x\n"
        "$ sort -o table table\n$ cat table\na:10:y\nb:2:x\nc:1:x\n$ \n"
    )


def test_sort_complains(shell):
    out = said(shell, "sort nothing\nsort -x\n")
    assert out == (
        "$ sort nothing\nsort: nothing: no such file or directory\nsh: exit 2\n"
        "$ sort -x\nusage: sort [-bfnru] [-t C] [-k N[,M]] [-o FILE] [FILE]...\n"
        "sh: exit 2\n$ \n"
    )


# --- diff -----------------------------------------------------------------------

OLD = "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\n"
NEW = "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n"


def test_diff_says_nothing_for_the_same_file(shell):
    out = said(shell, "diff old old\n", bin_disk(old=OLD))
    assert out == "$ diff old old\n$ \n"


def test_diff_normal_output(shell):
    on = bin_disk(old="1\n2\n3\n4\n5\n", new="0\n1\n3\nthree\n5\n6\n")
    assert output(shell, "diff old new", on) == (
        "0a1\n> 0\n2d2\n< 2\n4c4\n< 4\n---\n> three\n5a6\n> 6\nsh: exit 1\n"
    )


def test_diff_unified_output(shell):
    on = bin_disk(old=OLD, new=NEW)
    # Two changes six lines apart or less share a hunk; these are nine
    # apart, so they are two.
    assert output(shell, "diff -u old new", on) == (
        "--- old\n+++ new\n"
        "@@ -1,5 +1,5 @@\n a\n-b\n+B\n c\n d\n e\n"
        "@@ -9,3 +9,4 @@\n i\n j\n k\n+l\nsh: exit 1\n"
    )


def test_diff_marks_a_last_line_without_newline(shell):
    on = bin_disk(old="x\ny", new="x\ny\n")
    assert output(shell, "diff old new", on) == (
        "2c2\n< y\n\\ No newline at end of file\n---\n> y\nsh: exit 1\n"
    )


def test_diff_reads_standard_input_and_complains(shell):
    on = bin_disk(old=OLD)
    out = said(shell, "cat old | diff - old\ndiff old\ndiff old gone\n", on)
    assert out == (
        "$ cat old | diff - old\n"
        "$ diff old\nusage: diff [-u] FILE1 FILE2\nsh: exit 2\n"
        "$ diff old gone\ndiff: gone: no such file or directory\nsh: exit 2\n$ \n"
    )


def lcs(a: list[str], b: list[str]) -> int:
    """The length of the longest common subsequence of two lists."""
    row = [0] * (len(b) + 1)
    for x in a:
        prev = 0
        for j, y in enumerate(b):
            prev, row[j + 1] = (
                row[j + 1],
                prev + 1 if x == y else max(row[j + 1], row[j]),
            )
    return row[-1]


def test_diff_finds_a_shortest_script_that_patches(shell):
    """A shuffled file against itself sorted: the lines taken away and
    put in are as few as the longest common subsequence allows, and
    applying the hunks gives the second file."""
    old = [f"{(i * 37) % 23}" for i in range(40)]
    new = sorted(old, key=int)
    on = bin_disk(old="\n".join(old) + "\n", new="\n".join(new) + "\n")
    out = output(shell, "diff old new", on)
    lines = out.splitlines()
    assert lines[-1] == "sh: exit 1"
    removed = [x[2:] for x in lines if x.startswith("< ")]
    added = [x[2:] for x in lines if x.startswith("> ")]
    assert len(removed) + len(added) == len(old) + len(new) - 2 * lcs(old, new)
    # Apply the script, from the last change back, as patch would.
    result = list(old)
    heads = [x for x in lines if re.fullmatch(r"[\d,]+[acd][\d,]+", x)]
    for head in reversed(heads):
        a, op, b = re.fullmatch(r"([\d,]+)([acd])([\d,]+)", head).groups()
        a0, *a1 = map(int, a.split(","))
        a1 = a1[0] if a1 else a0
        body = lines[lines.index(head) + 1 :]
        put = [
            x[2:]
            for x in body[
                : next(
                    (
                        i
                        for i, x in enumerate(body)
                        if re.fullmatch(r"[\d,]+[acd][\d,]+|sh: .*", x)
                    ),
                    len(body),
                )
            ]
            if x.startswith("> ")
        ]
        if op == "a":
            result[a0:a0] = put
        else:
            result[a0 - 1 : a1] = put
    assert result == new
