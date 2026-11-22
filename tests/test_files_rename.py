"""The file server's rename (user/fsd.s, FS_RENAME): what one name names
takes another, in the same directory or another, replacing a file of
that name. Like the other calls that change the filesystem it checks
everything before it changes a block; tools/fs.py then reads the disk,
checking the whole tree, links and each directory's .. included."""

from tests.test_files import close, disk, open_, report, run, said, string
from tools import fs
from tools.fs import PAGE, Filesystem

L = fs.L


def rename(old: str, new: str) -> str:
    return f"""
        CALL_FS
        li    a2, FS_RENAME
        la    a3, {old}
        la    a4, {new}
        sys"""


def after(on) -> Filesystem:
    """The filesystem the run left on the disk, checked as it loads."""
    return Filesystem.load(on[0])


def names(made: Filesystem, path: str = "/") -> list[str]:
    return [n for n, _ in made.listdir(path)]


def test_a_file_takes_a_new_name_in_its_directory_or_another():
    program = report(
        rename("a", "b"),
        rename("b", "db"),
        rename("db", "dc"),
        data=string("a", "a")
        + string("b", "b")
        + string("db", "/d/b")
        + string("dc", "d/c"),
    )
    on = disk(dirs=("d",), a="kept\n")
    assert said(run(program, disk=on)) == [0, 0, 0]
    made = after(on)
    assert names(made) == ["d"]
    assert names(made, "d") == ["c"]
    assert made.read("d/c") == "kept\n"


def test_a_file_replaces_one_of_the_new_name_which_goes():
    program = report(
        rename("a", "b"),
        data=string("a", "a") + string("b", "b"),
    )
    on = disk(a="new", b="o" * (PAGE + 1))  # b holds two blocks
    free = len(Filesystem.load(on[0]).free_blocks())
    assert said(run(program, disk=on)) == [0]
    made = after(on)
    assert names(made) == ["b"]
    assert made.read("b") == "new"
    assert len(made.free_blocks()) == free + 2


def test_a_directory_moves_with_what_it_holds_and_a_new_parent():
    program = report(
        rename("a", "bc"),
        open_("abf"),  # the old path is gone,
        open_("bcf"),  # the new one reaches the file
        data=string("a", "a")
        + string("bc", "b/c")
        + string("abf", "a/f")
        + string("bcf", "b/c/f"),
    )
    on = disk(dirs=("a", "b"), a__f="in a\n")
    assert said(run(program, disk=on)) == [0, L["E_NOENT"], 0]
    made = after(on)  # checks .. and every link count
    assert names(made) == ["b"]
    assert names(made, "b") == ["c"]
    assert made.inode(made.lookup("b")).links == 3
    assert made.inode(made.lookup("/")).links == 3


def test_what_cannot_be_renamed_says_why_and_changes_nothing():
    program = report(
        rename("x", "y"),
        rename("f", "d"),  # a file over a directory
        rename("d", "f"),  # a directory over anything
        rename("d", "e"),
        rename("d", "dsub"),  # into itself
        rename("d", "dsubdeep"),
        rename("root", "y"),
        rename("f", "root"),
        rename("dot", "y"),
        rename("f", "dotdot"),
        rename("f", "space"),
        open_("g"),
        rename("f", "g"),  # g is open
        close(0),
        rename("f", "f"),  # the same: nothing to do
        rename("f", "nodir"),
        data=string("x", "x")
        + string("y", "y")
        + string("f", "f")
        + string("g", "g")
        + string("d", "d")
        + string("e", "e")
        + string("dsub", "d/sub")
        + string("dsubdeep", "d/s/deep")
        + string("root", "/")
        + string("dot", "d/.")
        + string("dotdot", "d/..")
        + string("space", "a b")
        + string("nodir", "no/f"),
    )
    on = disk(dirs=("d", "d/s", "e"), f="file\n", g="other\n")
    assert said(run(program, disk=on)) == [
        L["E_NOENT"],
        L["E_ISDIR"],
        L["E_EXIST"],
        L["E_EXIST"],
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_BUSY"],
        L["E_EXIST"],
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_INVAL"],
        0,
        L["E_BUSY"],
        0,
        0,
        L["E_NOENT"],
    ]
    made = after(on)
    assert names(made) == ["d", "e", "f", "g"]
    assert made.read("f") == "file\n"
    assert made.read("g") == "other\n"
