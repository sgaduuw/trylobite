"""sort, diff, find and tar of bin/, run from the shell on a disk of
bin/. sort reads every line before it writes, so `sort -o f f` is safe;
diff's output is what Unix's diff says for the same files; tar's archives
are ustar, so Python's tarfile reads them and makes ones it takes."""

import io
import re
import tarfile

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tools.fs import Filesystem

FRUIT = "pear 3\napple 10\nfig 2\nApple 7\npear 3\nbanana -1\n"
TABLE = "b:2:x\na:10:y\nc:1:x\n"


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


# 2023-11-14 22:13:20 UTC, a time for a file to keep.
WHEN = 1_700_000_000


def tree_disk(blocks: int = 90, **texts: str):
    """A disk of bin/ with a small tree, docs/ holding a.txt, b.md and
    sub/c.txt, beside the texts."""
    disk = bin_disk(blocks, **texts)
    fs = Filesystem.load(disk[0])
    fs.mkdir("docs")
    fs.write("docs/a.txt", "alpha\n")
    fs.write("docs/b.md", "# bee\n")
    fs.mkdir("docs/sub")
    fs.write("docs/sub/c.txt", "sea\n" * 300)  # over a record of 512
    fs.save(disk[0])
    return disk


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
        a, op, _ = re.fullmatch(r"([\d,]+)([acd])([\d,]+)", head).groups()
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


# --- find -----------------------------------------------------------------------


def test_find_walks_a_tree(shell):
    on = tree_disk(notes="n\n")
    assert output(shell, "find docs", on) == (
        "docs\ndocs/a.txt\ndocs/b.md\ndocs/sub\ndocs/sub/c.txt\n"
    )


def test_find_tests(shell):
    on = tree_disk(notes="n\n")
    out = said(
        shell,
        "find . -name '*.txt'\nfind docs -type d\nfind / -maxdepth 1 -type d\n"
        "find docs -name '[ab].*' -type f\nfind /bin -name 'f?nd'\n",
        on,
    )
    assert out == (
        "$ find . -name '*.txt'\n./docs/a.txt\n./docs/sub/c.txt\n"
        "$ find docs -type d\ndocs\ndocs/sub\n"
        "$ find / -maxdepth 1 -type d\n/\n/bin\n/docs\n"
        "$ find docs -name '[ab].*' -type f\ndocs/a.txt\ndocs/b.md\n"
        "$ find /bin -name 'f?nd'\n/bin/find\n$ \n"
    )


def test_find_goes_deeper_than_its_descriptors(shell):
    """Ten directories deep, more than a program's nine descriptors."""
    disk = bin_disk()
    fs = Filesystem.load(disk[0])
    path = ""
    for i in range(10):
        path += f"d{i}/"
        fs.mkdir(path.rstrip("/"))
    fs.write(path + "end", "x\n")
    fs.save(disk[0])
    assert output(shell, "find d0 -name end", disk) == (
        "d0/d1/d2/d3/d4/d5/d6/d7/d8/d9/end\n"
    )


def test_find_complains(shell):
    out = said(shell, "find nothing docs\nfind -size 3\n", tree_disk())
    assert out.startswith(
        "$ find nothing docs\nfind: nothing: no such file or directory\ndocs\n"
    )
    assert out.endswith(
        "sh: exit 1\n$ find -size 3\n"
        "usage: find [PATH]... [-name PATTERN] [-type f|d] [-maxdepth N]\n"
        "sh: exit 2\n$ \n"
    )


# --- tar ------------------------------------------------------------------------


def archive(fs: Filesystem, path: str) -> tarfile.TarFile:
    """The archive at path, its trytes as bytes, opened by Python."""
    trytes = fs.read_trytes(path)
    assert all(0 <= t < 256 for t in trytes)
    return tarfile.open(fileobj=io.BytesIO(bytes(trytes)))


def test_tar_makes_an_archive_any_tar_reads(shell):
    on = tree_disk(notes="some notes\n")
    out = said(shell, "tar cvf a.tar docs notes\n", on)
    assert out == (
        "$ tar cvf a.tar docs notes\n"
        "docs/\ndocs/a.txt\ndocs/b.md\ndocs/sub/\ndocs/sub/c.txt\nnotes\n$ \n"
    )
    fs = Filesystem.load(on[0])
    with archive(fs, "a.tar") as tar:
        assert tar.getnames() == [
            "docs",
            "docs/a.txt",
            "docs/b.md",
            "docs/sub",
            "docs/sub/c.txt",
            "notes",
        ]
        assert tar.getmember("docs/sub").isdir()
        assert tar.extractfile("docs/sub/c.txt").read() == b"sea\n" * 300
        assert tar.extractfile("notes").read() == b"some notes\n"
    assert len(fs.read_trytes("a.tar")) % 512 == 0


def test_tar_lists_and_extracts(shell):
    on = tree_disk(notes="some notes\n")
    fs = Filesystem.load(on[0])
    fs.chmod("docs/a.txt", 0o600)
    fs.chown("docs/a.txt", 5, 7)
    fs.utimes("docs/a.txt", WHEN, WHEN)
    fs.save(on[0])
    out = said(
        shell,
        "tar cf a.tar docs notes\ntar tvf a.tar\nmkdir out\ncd out\n"
        "tar xf ../a.tar\ncd ..\ndiff -u docs/sub/c.txt out/docs/sub/c.txt\n"
        "mkdir part\ncd part\ntar -x -v -f ../a.tar docs/sub\nfind .\n",
        on,
    )
    assert (
        "$ tar tvf a.tar\n"
        + (
            "d        0 docs/\n"
            "-        6 docs/a.txt\n"
            "-        6 docs/b.md\n"
            "d        0 docs/sub/\n"
            "-     1200 docs/sub/c.txt\n"
            "-       11 notes\n"
        )
        in out
    )
    assert "$ diff -u docs/sub/c.txt out/docs/sub/c.txt\n$ " in out
    assert out.endswith(
        "docs/sub/\ndocs/sub/c.txt\n"
        "$ find .\n.\n./docs\n./docs/sub\n./docs/sub/c.txt\n$ \n"
    )
    fs = Filesystem.load(on[0])
    assert fs.read("out/notes") == "some notes\n"
    assert fs.read("out/docs/b.md") == "# bee\n"
    # Each member keeps its mode, owner and time, and the mode and time
    # come back.
    with archive(fs, "a.tar") as tar:
        a = tar.getmember("docs/a.txt")
        assert (a.mode, a.uid, a.gid, a.mtime) == (0o600, 5, 7, WHEN)
    made = fs.stat("out/docs/a.txt")
    assert (made.mode, made.mtime.secs) == (0o600, WHEN)


def test_tar_through_a_pipe_and_with_programs(shell):
    on = tree_disk()
    out = said(
        shell,
        "tar cf - docs/sub bin/hello | tar tf -\n"
        "tar cf p.tar bin/hello\nmkdir x\ncd x\ntar xf ../p.tar\n",
        on,
    )
    assert out.startswith(
        "$ tar cf - docs/sub bin/hello | tar tf -\n"
        "docs/sub/\ndocs/sub/c.txt\nbin/hello\n"
    )
    fs = Filesystem.load(on[0])
    assert fs.read_trytes("x/bin/hello") == fs.read_trytes("bin/hello")


def test_tar_takes_an_archive_python_made(shell):
    made = io.BytesIO()
    with tarfile.open(fileobj=made, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for name, data in [("t/one", b"1\n"), ("t/deep/two", b"2" * 700)]:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
        info = tarfile.TarInfo("../escape")
        info.size = 1
        tar.addfile(info, io.BytesIO(b"!"))
    disk = bin_disk()
    fs = Filesystem.load(disk[0])
    fs.write_trytes("py.tar", list(made.getvalue()))
    fs.save(disk[0])
    out = said(shell, "tar xf py.tar\n", disk)
    assert out == (
        "$ tar xf py.tar\ntar: ../escape: member name contains '..'\nsh: exit 2\n$ \n"
    )
    fs = Filesystem.load(disk[0])
    assert fs.read("t/one") == "1\n"
    assert fs.read("t/deep/two") == "2" * 700
    assert fs.lookup("escape") is None


def test_tar_leaves_out_the_archive_and_complains(shell):
    on = tree_disk()
    out = said(
        shell, "tar cf docs/in.tar docs\ntar tf docs/in.tar\ntar q\ntar xf gone\n", on
    )
    assert out == (
        "$ tar cf docs/in.tar docs\ntar: docs/in.tar: is the archive; not dumped\n"
        "$ tar tf docs/in.tar\n"
        "docs/\ndocs/a.txt\ndocs/b.md\ndocs/sub/\ndocs/sub/c.txt\n"
        "$ tar q\nusage: tar -c|-t|-x [-v] [-f ARCHIVE] [PATH]...\nsh: exit 2\n"
        "$ tar xf gone\ntar: gone: no such file or directory\nsh: exit 2\n$ \n"
    )
