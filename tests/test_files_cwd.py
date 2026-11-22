"""Each process's current directory in the file server (user/fsd.s):
chdir and getcwd, paths that start there because they do not start with
a slash, and programs that start in their parent's."""

from tests.kernel import wait_for
from tests.test_files import disk, disk_program, open_, read, report, run, said, string
from tests.test_files_write import call
from tools import fs
from tools.fs import Filesystem

L = fs.L


def getcwd(n: int = 50) -> str:
    """getcwd into buf, then buf printed and a space."""
    return f"""
        li    a0, SYS_CALL
        li    a1, FS_PID
        li    a2, FS_GETCWD
        la    a3, buf
        li    a4, {n}
        sys
        mv    s1, a0
        bltz  a0, 1f
        li    a0, SYS_PUTS
        la    a1, buf
        sys
        li    a0, SYS_PUTC
        li    a1, ' '
        sys
1:      mv    a0, s1"""


def test_chdir_moves_where_paths_without_a_slash_start():
    program = report(
        getcwd(),
        call("FS_CHDIR", "d"),
        getcwd(),
        open_("f"),  # d/f
        read(0, 50),
        open_("rootf"),  # /f
        call("FS_CHDIR", "e"),
        getcwd(),
        call("FS_CHDIR", "up"),  # ../..
        getcwd(),
        call("FS_CHDIR", "de"),  # d//e/
        getcwd(),
        getcwd(5),  # /d/e and its 0 need 5
        getcwd(4),
        data=string("d", "d")
        + string("f", "f")
        + string("rootf", "/f")
        + string("e", "e")
        + string("up", "../..")
        + string("de", "d//e/"),
    )
    result = run(program, disk=disk(dirs=("d", "d/e"), f="top", d__f="inside d"))
    assert said(result) == [1, 0, 2, 0, 8, 1, 0, 4, 0, 1, 0, 4, 4, L["E_NOROOM"]]
    words = result.console.split()
    assert [w for w in words if w[0] == "/"] == ["/", "/d", "/d/e", "/", "/d/e", "/d/e"]


def test_what_chdir_and_getcwd_refuse():
    program = report(
        call("FS_CHDIR", "f"),
        call("FS_CHDIR", "nope"),
        call("FS_CHDIR", "empty"),
        open_("empty"),
        call("FS_CHDIR", "d"),
        getcwd(-1),
        """
        li    a0, SYS_CALL
        li    a1, FS_PID
        li    a2, FS_GETCWD
        li    a3, V_USER + 9840         # runs past the page
        li    a4, 10
        sys""",
        data=string("f", "f")
        + string("nope", "nope")
        + string("empty", "")
        + string("d", "d"),
    )
    assert said(run(program, disk=disk(dirs=("d",), f="x"))) == [
        L["E_NOTDIR"],
        L["E_NOENT"],
        L["E_NOENT"],
        L["E_NOENT"],
        0,
        L["E_NOROOM"],
        L["E_FAULT"],
    ]


def test_relative_paths_change_the_filesystem_and_a_current_directory_is_busy():
    program = report(
        call("FS_CHDIR", "d"),
        call("FS_MKDIR", "sub"),
        open_("subf", "O_WRONLY + O_CREAT"),
        call("FS_UNLINK", "dotf"),  # ./old
        call("FS_MKDIR", "e"),
        call("FS_CHDIR", "e"),
        call("FS_RMDIR", "here"),  # /d/e, the current directory
        call("FS_RMDIR", "dot"),  # .
        call("FS_CHDIR", "root"),
        call("FS_RMDIR", "here"),
        data=string("d", "d")
        + string("sub", "sub")
        + string("subf", "sub/f")
        + string("dotf", "./old")
        + string("e", "e")
        + string("here", "/d/e")
        + string("dot", ".")
        + string("root", "/"),
    )
    on = disk(dirs=("d",), d__old="x")
    assert said(run(program, disk=on)) == [
        0,
        0,
        0,
        0,
        0,
        0,
        L["E_BUSY"],
        L["E_INVAL"],
        0,
        0,
    ]
    made = Filesystem.load(on[0])
    assert [n for n, _ in made.listdir("d")] == ["sub"]
    assert [n for n, _ in made.listdir("d/sub")] == ["f"]


def test_a_program_starts_in_its_parents_directory():
    # where prints its directory, moves to /, and exits with how long
    # the first was; its parent's own directory does not move.
    where = disk_program("""
        li    a0, SYS_CALL
        li    a1, FS_PID
        li    a2, FS_GETCWD
        la    a3, buf
        li    a4, 50
        sys
        mv    s1, a0
        li    a0, SYS_PUTS
        la    a1, buf
        sys
        li    a0, SYS_CALL
        li    a1, FS_PID
        li    a2, FS_CHDIR
        la    a3, root
        sys
        mv    a1, s1
        li    a0, SYS_EXIT
        sys
root:   .string "/"
buf:    .zero 50
""")
    program = report(
        call("FS_CHDIR", "deep"),
        """
        li    a0, SYS_CALL
        li    a1, FS_PID
        li    a2, FS_SPAWN
        la    a3, where
        sys
        mv    s1, a0""",
        wait_for("s1") + "\n        mv    a0, a1",
        getcwd(),
        data=string("deep", "/a/b") + string("where", "/bin/where"),
    )
    on = disk(dirs=("bin", "a", "a/b"), bin__where=where)
    result = run(program, disk=on)
    assert said(result) == [0, 2, 4, 4]
    assert result.console.count("/a/b") == 2


def test_a_process_that_ends_leaves_its_directory_free():
    child = """
        li    a0, SYS_CALL
        li    a1, FS_PID
        li    a2, FS_CHDIR
        la    a3, cd
        sys
        mv    a1, a0
        li    a0, SYS_EXIT
        sys
cd:     .string "d"
"""
    program = report(
        """
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0""",
        wait_for("s1") + "\n        mv    a0, a1",
        call("FS_RMDIR", "d"),
        data=string("d", "d"),
    )
    assert said(run(program, child, disk=disk(dirs=("d",)))) == [2, 0, 0]
