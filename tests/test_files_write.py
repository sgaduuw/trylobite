"""The file server's calls that change the filesystem (user/rust/fsd):
open with O_CREAT, O_TRUNC and O_APPEND, write, unlink, mkdir and rmdir.
Each is a transaction: the server writes every block it changed, then
the superblock, before it replies, or forgets them all when the call
fails; tools/fs.py then reads the disk, checking the whole tree as it
loads it."""

from tests.kernel import exit_with, wait_for
from tests.test_files import (
    close,
    disk,
    lseek,
    open_,
    read,
    report,
    run,
    said,
    string,
)
from tools import fs
from tools.fs import PAGE, Filesystem

L = fs.L
W, C, T, A = L["O_WRONLY"], L["O_CREAT"], L["O_TRUNC"], L["O_APPEND"]


def write(fd: int, n: int, src: str = "text") -> str:
    return f"""
        li    a0, SYS_WRITE
        li    a1, {fd}
        la    a2, {src}
        li    a3, {n}
        sys"""


def call(op: str, path: str) -> str:
    return f"""
        CALL_FS
        li    a2, {op}
        la    a3, {path}
        sys"""


CLOSE_0 = close(0)


def after(on) -> Filesystem:
    """The filesystem the run left on the disk, checked as it loads."""
    return Filesystem.load(on[0])


def test_a_new_file_holds_what_was_written():
    program = report(
        open_("p", W + C),
        write(0, 5),
        write(0, 3),
        data=string("p", "/notes") + string("text", "hello"),
    )
    on = disk()
    assert said(run(program, disk=on)) == [0, 5, 3]
    made = after(on)
    assert made.read("notes") == "hellohel"
    assert made.inode(made.lookup("notes")).links == 1


def test_writing_stops_at_a_block_end_and_grows_the_file():
    program = report(
        open_("p", W + C),
        lseek(0, PAGE - 2, "SEEK_SET"),
        write(0, 5),  # two fit in block 0
        write(0, 5),  # the rest go to a new block 1
        data=string("p", "f") + string("text", "abcde"),
    )
    on = disk()
    assert said(run(program, disk=on)) == [0, PAGE - 2, 2, 5]
    text = after(on).read("f")
    assert text == "\0" * (PAGE - 2) + "ab" + "abcde"


def test_a_write_far_out_leaves_a_hole():
    # The blocks before the one written are not there: an extent holds
    # only the block written, and they read as zeros.
    far = 5 * PAGE + 3
    program = report(
        open_("p", W + C),
        lseek(0, far, "SEEK_SET"),
        write(0, 4),
        data=string("p", "sparse") + string("text", "tail"),
    )
    on = disk()
    free = len(after(on).free_blocks())
    assert said(run(program, disk=on)) == [0, far, 4]
    made = after(on)
    node = made.stat("sparse")
    assert node.size == far + 4
    assert node.data[:5] == [L["NO_BLOCK"]] * 5 and node.data[5] != L["NO_BLOCK"]
    assert made.read_trytes("sparse")[far:] == [ord(c) for c in "tail"]
    assert made.read_trytes("sparse")[:far] == [0] * far
    assert len(made.free_blocks()) == free - 1  # the one data block


def test_o_trunc_empties_and_o_append_adds():
    program = report(
        open_("big", W + T),
        open_("log", W + A),
        write(1, 4),
        lseek(1, 0, "SEEK_SET"),
        write(1, 4),  # still at the end
        open_("log", L["O_RDWR"] + C),  # there already: kept as it is
        read(2, 50),
        data=string("big", "big") + string("log", "log") + string("text", "more"),
    )
    on = disk(big="x" * (2 * PAGE), log="start:")
    free = len(after(on).free_blocks())
    assert said(run(program, disk=on)) == [0, 1, 4, 0, 4, 2, 14]
    made = after(on)
    assert made.read("big") == ""
    assert made.read("log") == "start:moremore"
    assert len(made.free_blocks()) == free + 2  # big's


def test_what_cannot_be_written_says_why():
    program = report(
        open_("f"),  # for reading only
        write(0, 1),
        open_("f", W),
        read(1, 1),
        open_("d", W),  # a directory
        open_("nope", W),  # not there, and no O_CREAT
        open_("f", "6"),  # O_CREAT twice
        open_("f", str(3 * A)),
        write(1, -1),
        open_("d", L["O_RDONLY"] + C),  # a directory may be opened so
        data=string("f", "f")
        + string("d", "d")
        + string("nope", "nope")
        + string("text", "x"),
    )
    assert said(run(program, disk=disk(dirs=("d",), f="x"))) == [
        0,
        L["E_BADF"],
        1,
        L["E_BADF"],
        L["E_ISDIR"],
        L["E_NOENT"],
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_INVAL"],
        2,
    ]


def test_unlink_frees_a_file_and_refuses_what_it_cannot_remove():
    program = report(
        call("FS_UNLINK", "a"),
        call("FS_UNLINK", "a"),
        call("FS_UNLINK", "d"),
        call("FS_UNLINK", "dot"),
        open_("b"),
        call("FS_UNLINK", "b"),  # open
        CLOSE_0,
        call("FS_UNLINK", "b"),
        data=string("a", "a")
        + string("b", "/d/b")
        + string("d", "d")
        + string("dot", "d/."),
    )
    on = disk(dirs=("d",), a="x" * (PAGE + 1), d__b="y")
    free = len(after(on).free_blocks())
    assert said(run(program, disk=on)) == [
        0,
        L["E_NOENT"],
        L["E_ISDIR"],
        L["E_INVAL"],
        0,
        L["E_BUSY"],
        0,
        0,
    ]
    made = after(on)
    assert made.listdir() == [("d", made.inode(made.lookup("d")))]
    assert made.listdir("d") == []
    assert len(made.free_blocks()) == free + 3  # a's two and b's
    assert made.info()["inodes"] == 2  # / and d


def test_mkdir_and_rmdir():
    program = report(
        call("FS_MKDIR", "a"),
        call("FS_MKDIR", "ab"),
        call("FS_MKDIR", "a"),
        call("FS_MKDIR", "nope"),
        open_("abf", W + C),
        call("FS_MKDIR", "ac"),
        open_("ac"),
        call("FS_RMDIR", "a"),  # not empty
        call("FS_RMDIR", "ac"),  # open
        call("FS_RMDIR", "f"),
        call("FS_RMDIR", "root"),
        call("FS_MKDIR", "dot"),
        data=string("a", "a")
        + string("ab", "/a/b/")
        + string("abf", "a/b/f")
        + string("ac", "a/c")
        + string("nope", "x/y")
        + string("f", "a/b/f")
        + string("root", "/")
        + string("dot", "a/.."),
    )
    on = disk()
    free = len(after(on).free_blocks())
    assert said(run(program, disk=on)) == [
        0,
        0,
        L["E_EXIST"],
        L["E_NOENT"],
        0,
        0,
        1,
        L["E_NOTEMPTY"],
        L["E_BUSY"],
        L["E_NOTDIR"],
        L["E_BUSY"],
        L["E_EXIST"],  # a/.. is there, as POSIX's mkdir says
    ]
    made = after(on)
    assert made.inode(made.lookup("a")).links == 4
    assert made.inode(made.lookup("/")).links == 3
    assert [n for n, _ in made.listdir("a/b")] == ["f"]

    program = report(
        call("FS_UNLINK", "f"),
        call("FS_RMDIR", "b"),
        call("FS_RMDIR", "c"),
        call("FS_RMDIR", "a"),
        data=string("f", "a/b/f")
        + string("b", "a/b")
        + string("c", "a/c")
        + string("a", "a"),
    )
    assert said(run(program, disk=on)) == [0, 0, 0, 0]
    made = after(on)
    assert made.listdir() == []
    assert made.inode(L["ROOT_INO"]).links == 2
    assert len(made.free_blocks()) == free  # directories take no blocks


def test_a_full_disk_says_so_and_stays_whole():
    # Four blocks: the superblock, the tree's one leaf, and two free. Each
    # change writes the leaf afresh (copy on write), so a block for data
    # and one for the leaf is all a call can have: the second block of
    # data finds no room. A directory takes no block of its own.
    program = report(
        open_("p", W + C),
        write(0, 1),
        lseek(0, PAGE, "SEEK_SET"),
        write(0, 1),  # a second block: there is none
        call("FS_MKDIR", "d"),
        data=string("p", "f") + string("text", "x") + string("d", "d"),
    )
    on = disk(4)
    assert said(run(program, disk=on)) == [0, 1, PAGE, L["E_NOSPC"], 0]
    made = after(on)
    assert made.read("f") == "x"
    assert made.is_dir("d")


def test_two_processes_write_at_once():
    def writer(path: str, char: str, p: str) -> str:
        return f"""
        .gp   USER_GP
        CALL_FS
        li    a2, FS_OPEN
        la    a3, {p}path
        li    a4, {W + C}
        sys
        mv    s2, a0
        li    s1, 30
1:      li    a0, SYS_WRITE
        mv    a1, s2
        la    a2, {p}text
        li    a3, 7
        sys
        bltz  a0, 9f
        addi  s1, s1, -1
        bnez  s1, 1b
        li    a0, 0
9:      {exit_with("a0")}
{p}path: .string "{path}"
{p}text: .string "{char * 7}"
"""

    init = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        li    a0, SYS_SPAWN
        li    a1, 2
        sys
        mv    s2, a0
        {wait_for("s1")}
        mv    s3, a1
        {wait_for("s2")}
        add   a1, a1, s3
        {exit_with("a1")}
"""
    on = disk(dirs=("d",))
    result = run(
        init,
        writer("d/one", "1", "a"),
        writer("two", "2", "b"),
        disk=on,
        max_steps=20_000_000,
    )
    assert result.code_of(0) == 0
    made = after(on)
    assert made.read("d/one") == "1" * 210
    assert made.read("two") == "2" * 210


def test_a_file_of_more_blocks_than_the_server_keeps_windows_for():
    # The server keeps NWIN blocks at a time; a file of twelve, written a
    # block at a time and read back, has it put blocks it changed aside
    # (they are on the disk by then) to take others.
    steps = [lseek(0, k * PAGE, "SEEK_SET") + write(0, 3) for k in range(12)]
    reads = [
        lseek(0, k * PAGE, "SEEK_SET") + read(0, 1, f"buf + {k}") for k in range(12)
    ]
    program = report(
        open_("p", L["O_RDWR"] + C),
        *steps,
        *reads,
        data=string("p", "f") + string("text", "abc"),
    )
    on = disk(20)
    result = run(program, disk=on, max_steps=40_000_000)
    assert said(result) == [0] + [3] * 12 + [1] * 12
    trytes = after(on).read_trytes("f")
    assert [trytes[k * PAGE] for k in range(12)] == [ord("a")] * 12
