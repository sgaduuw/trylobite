"""The file server's calls (docs/filesystem.md, user/fsd.s): open, close,
read, lseek, readdir, stat and spawnf, reading disks tools/fs.py made.
Each is a call to the server, found by its name (CALL_FS, tests/kernel.py);
the harness builds the server in and init starts it first."""

import re

from tests import kernel
from tests.kernel import EXIT, _assemble, exit_with, find_servers, new_disk, wait_for
from tools import fs
from tools.fs import PAGE, Filesystem, program_file

L = fs.L


def run(*args, **options):
    """kernel.run, with the file server built in and started first."""
    return kernel.run(*args, files=True, **options)


# putn: print a0 in decimal and a space, in one puts, so that a child's
# output cannot come between them. Clobbers a0, a1, t0..t3.
PUTN = """
putn:   mv    t3, a0
        la    t2, digits_end
        li    t0, ' '
        st    t0, 0(t2)
        li    t1, 10
1:      rem   t0, t3, t1
        bgez  t0, 2f
        sub   t0, zero, t0
2:      addi  t0, t0, '0'
        addi  t2, t2, -1
        st    t0, 0(t2)
        div   t3, t3, t1
        bnez  t3, 1b
        bgez  a0, 3f
        li    t0, '-'
        addi  t2, t2, -1
        st    t0, 0(t2)
3:      mv    a1, t2
        li    a0, SYS_PUTS
        sys
        ret
digits: .zero 12
digits_end: .tryte 0, 0
"""


def report(*steps: str, data: str = "") -> str:
    """A program that does each step, printing the a0 it leaves, then exits."""
    body = "\n".join(f"{step}\n        call  putn" for step in steps)
    return f"""
        .gp   USER_GP
{body}
        li    a1, 0
        li    a0, SYS_EXIT
        sys
{PUTN}
        .align 3
statbuf: .words 4
buf:    .zero 300
buf_end:
{data}
"""


def disk(blocks: int = 8, dirs=(), **files: str | list[int]):
    """A disk holding these directories and files; a name's __ is a /."""
    path = new_disk()
    made = Filesystem.new(blocks)
    for name in dirs:
        made.mkdir(name)
    for name, contents in files.items():
        name = name.replace("__", "/")
        if isinstance(contents, str):
            made.write(name, contents)
        else:
            made.write_trytes(name, contents)
    made.save(path)
    return path, blocks


def said(result) -> list[int]:
    """The numbers the program printed, leaving out the kernel's lines and
    any words a child printed."""
    text = re.sub(r"trylobite: [^\n]*\n", " ", result.console)
    return [int(n) for n in text.split() if re.fullmatch(r"-?\d+", n)]


def open_(path: str, flags: str = "O_RDONLY") -> str:
    return f"""
        CALL_FS
        li    a2, FS_OPEN
        la    a3, {path}
        li    a4, {flags}
        sys"""


def read(fd: int | str, n: int | str, to: str = "buf") -> str:
    load = "la" if to.isidentifier() else "li"  # a label, or an address
    return f"""
        li    a0, SYS_READ
        li    a1, {fd}
        {load}    a2, {to}
        li    a3, {n}
        sys"""


def lseek(fd: int, offset: int, whence: str) -> str:
    return f"""
        li    a0, SYS_IOCALL
        li    a1, {fd}
        li    a2, IO_LSEEK
        li    a3, {offset}
        li    a4, {whence}
        sys"""


def close(fd: int | str) -> str:
    return f"""
        li    a0, SYS_CLOSE
        li    a1, {fd}
        sys"""


def string(label: str, text: str) -> str:
    return f'{label}: .string "{text}"\n'


def test_a_file_reads_up_to_the_end_of_its_block_and_its_end():
    text = "".join(chr(ord("a") + i % 26) for i in range(PAGE + 5))
    program = report(
        open_("p"),
        read(0, 10),
        lseek(0, PAGE - 3, "SEEK_SET"),
        read(0, 10),  # the rest of block 0: 3
        read(0, 10),  # block 1 holds the last 5
        read(0, 10),  # the end
        "        lt    a0, buf",  # the last read left the file's last tryte...
        "        lt    a0, buf + 4",
        data=string("p", "/big"),
    )
    result = run(program, disk=disk(big=text))
    assert said(result) == [0, 10, PAGE - 3, 3, 5, 0, ord(text[-5]), ord(text[-1])]


def test_a_big_file_reads_through_its_indirect_block():
    n = L["NDIRECT"] * PAGE + 20
    text = "".join(chr(ord("A") + (i // PAGE)) for i in range(n))
    program = report(
        open_("p"),
        lseek(0, L["NDIRECT"] * PAGE + 2, "SEEK_SET"),
        read(0, 100),
        "        lt    a0, buf",
        lseek(0, -1, "SEEK_END"),
        lseek(0, -2, "SEEK_CUR"),
        read(0, 100),
        data=string("p", "big"),
    )
    result = run(program, disk=disk(12, big=text))
    assert said(result) == [0, L["NDIRECT"] * PAGE + 2, 18, ord("F"), n - 1, n - 3, 3]


def test_a_path_goes_through_directories():
    program = report(
        open_("p1"),
        read(0, 50),
        open_("p2"),
        read(1, 50),
        "        lt    a0, buf",
        data=string("p1", "a/b/c") + string("p2", "//a/./b/..//b/c/"),
    )
    on = disk(dirs=("a", "a/b"), a__b__c="deep")
    assert said(run(program, disk=on)) == [0, 4, 1, 4, ord("d")]


def test_what_cannot_be_opened_says_why():
    deep = "/".join(["d" * 17] * 14)  # 251 trytes: more than PATH_MAX
    program = report(
        open_("missing"),
        open_("through"),
        open_("long"),
        open_("deep"),
        open_("f", "6"),  # O_CREAT twice
        """
        CALL_FS
        li    a2, FS_OPEN
        li    a3, V_USER - 9842
        li    a4, O_RDONLY
        sys""",
        data=string("missing", "nope")
        + string("through", "f/x")
        + string("long", "x" * 18)
        + string("deep", deep)
        + string("f", "f"),
    )
    dirs = ["/".join("abcdef"[:n]) for n in range(1, 7)]
    assert said(run(program, disk=disk(12, dirs=dirs, f="x"))) == [
        L["E_NOENT"],
        L["E_NOTDIR"],
        L["E_NAMETOOLONG"],
        L["E_NAMETOOLONG"],
        L["E_INVAL"],
        L["E_FAULT"],
    ]


def test_descriptors_are_the_lowest_free_and_there_are_ndesc():
    # Open's descriptor is the kernel's (kernel/desc.s): the caller's lowest
    # free one, of NDESC.
    program = report(
        *[open_("f")] * (L["NDESC"] + 1),
        close(3),
        open_("f"),
        close(3),
        close(3),
        close("NDESC"),
        data=string("f", "f"),
    )
    assert said(run(program, disk=disk(f="x"))) == [
        *range(L["NDESC"]),
        L["E_MFILE"],
        0,
        3,
        0,
        L["E_BADF"],
        L["E_BADF"],
    ]


def test_closing_frees_the_file_for_another_open():
    # More opens than the server keeps files: each close lets the kernel
    # tell the server the file's handle is free.
    step = open_("f") + "\n        mv    s1, a0" + close(0) + "\n        mv    a0, s1"
    program = report(*[step] * (L["NFILE"] + 2), data=string("f", "f"))
    assert said(run(program, disk=disk(f="x"))) == [0] * (L["NFILE"] + 2)


def test_copies_of_a_descriptor_share_the_file_and_its_position():
    # dup2 copies the descriptor, so both name one open file, as after
    # Unix's dup; a child's inherited copy does too.
    child = f"""
        .gp   USER_GP
        {read(4, 1, to="cbuf")}
        lt    a1, cbuf
        {EXIT}
cbuf:   .zero 1
"""
    init = report(
        open_("f"),
        "li a0, SYS_DUP2\n        li a1, 0\n        li a2, 4\n        sys",
        read(0, 1),
        "lt a0, buf",
        read(4, 1),
        "lt a0, buf",
        f"li a0, SYS_SPAWN\n        li a1, 1\n        sys\n        mv s1, a0\n"
        f"        {wait_for('s1')}\n        mv a0, a1",
        read(0, 1),
        "lt a0, buf",
        data=string("f", "f"),
    )
    assert said(run(init, child, disk=disk(f="abcd"))) == [
        0,
        4,
        1,
        ord("a"),
        1,
        ord("b"),
        ord("c"),  # what the child read
        1,
        ord("d"),
    ]


def test_the_old_descriptor_calls_are_gone():
    # Close, read, lseek, readdir and write were FS_ calls; they are
    # descriptor calls now, and the numbers are refused.
    def call(op: int) -> str:
        return f"CALL_FS\n        li a2, {op}\n        li a3, 0\n        sys"

    program = report(
        open_("f"), *[call(op) for op in (1, 2, 3, 4, 7)], data=string("f", "f")
    )
    assert said(run(program, disk=disk(f="x"))) == [0] + [L["E_INVAL"]] * 5


def test_reads_and_seeks_that_cannot_be_done():
    program = report(
        open_("f"),
        open_("d"),
        read(2, 1),  # not open
        read(1, 1),  # a directory
        read(0, -1),
        read(0, 2, to="V_USER + 9841"),  # its last tryte is past the page
        read(0, 1, to="V_USER + 9841"),  # just fits
        lseek(0, -1, "SEEK_SET"),
        lseek(0, 0, "3"),
        lseek(0, 99, "SEEK_SET"),  # past the end is allowed,
        read(0, 1),  # and reads nothing
        data=string("f", "f") + string("d", "/"),
    )
    assert said(run(program, disk=disk(f="xy"))) == [
        0,
        1,
        L["E_BADF"],
        L["E_ISDIR"],
        L["E_INVAL"],
        L["E_FAULT"],
        1,
        L["E_INVAL"],
        L["E_INVAL"],
        99,
        0,
    ]


def readdir(fd: int) -> str:
    return f"""
        li    a0, SYS_IOCALL
        li    a1, {fd}
        li    a2, IO_READDIR
        la    a3, buf
        sys"""


def test_readdir_gives_each_entry_in_use_and_then_0():
    step = f"""
        {readdir(0)}
        mv    s1, a0
        blez  a0, 1f
        li    a0, SYS_PUTS
        la    a1, buf
        sys
        li    a0, SYS_PUTC
        li    a1, ' '
        sys
1:      mv    a0, s1"""
    program = report(
        open_("d"),
        *[step] * 6,
        lseek(0, 0, "SEEK_SET"),
        step,
        open_("f"),
        readdir(1),
        data=string("d", "/d") + string("f", "/d/one"),
    )
    made = disk(dirs=("d",), d__one="1", d__gone="", d__three="3")
    fs_ = Filesystem.load(made[0])
    fs_.remove("d/gone")  # an unused entry in the middle
    fs_.save(made[0])
    d, one, three = (fs_.lookup(p) for p in ("d", "d/one", "d/three"))
    out = run(program, disk=made).after_boot.split("trylobite")[0]
    assert out.split() == [
        "0",
        ".",
        str(d),
        "..",
        str(L["ROOT_INO"]),
        "one",
        str(one),
        "three",
        str(three),
        "0",
        "0",  # the end, and still the end
        "0",
        ".",
        str(d),
        "1",
        str(L["E_NOTDIR"]),
    ]


def test_stat_says_what_a_path_names():
    def stat(path: str, to: str = "statbuf") -> str:
        return f"""
        CALL_FS
        li    a2, FS_STAT
        la    a3, {path}
        la    a4, {to}
        sys"""

    fields = [f"        lw    a0, statbuf + ST_{f}" for f in ("INO", "TYPE", "LINKS")]
    program = report(
        stat("f"),
        *fields,
        "        lw    a0, statbuf + ST_SIZE",
        stat("d"),
        *fields,
        stat("f", "statbuf + 1"),  # not a word's address
        stat("nope"),
        data=string("f", "d/f") + string("d", "d") + string("nope", "nope"),
    )
    made = disk(dirs=("d", "d/e"), d__f="12345")
    fs_ = Filesystem.load(made[0])
    f, d = fs_.lookup("d/f"), fs_.lookup("d")
    assert said(run(program, disk=made)) == [
        0,
        f,
        L["T_FILE"],
        1,
        5,
        0,
        d,
        L["T_DIR"],
        3,
        L["E_FAULT"],
        L["E_NOENT"],
    ]


def test_without_a_filesystem_there_are_no_files():
    program = report(open_("f"), data=string("f", "f"))
    assert said(run(program)) == [L["E_NOFS"]]  # no disk
    assert said(run(program, disk=(new_disk(), 3))) == [L["E_NOFS"]]  # blank


def test_descriptors_go_with_their_process():
    # Each child opens every descriptor and exits with them open: more
    # files, all told, than the server keeps (NFILE), so each must be
    # closed when the kernel says no descriptor names it any more.
    child = report(*[open_("f")] * L["NDESC"], data=string("f", "f"))
    children = L["NFILE"] // L["NDESC"] + 1
    init = f"""
        li    s2, {children}
1:      li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        {wait_for("s1")}
        addi  s2, s2, -1
        bnez  s2, 1b
        li    a1, 0
        {exit_with("s1")}
"""
    result = run(init, child, disk=disk(f="x"))
    assert result.code_of(0) == 3 + children - 1  # after the two servers
    assert L["NDESC"] * children > L["NFILE"]
    assert said(result) == list(range(L["NDESC"])) * children


def test_a_server_without_pages_for_its_windows_says_so():
    # The build has 5 programs, so pages 11 to 26 are free, less one for
    # the kernel's log; init and the two servers take 4 each, the disk
    # server a window more, leaving 2 windows, and an open needs three
    # blocks: block 0, the inodes and the root directory.
    program = report(open_("f"), data=string("f", "f"))
    assert said(run(program, ram_pages=26, disk=disk(f="x"))) == [L["E_NOMEM"]]
    assert said(run(program, ram_pages=27, disk=disk(f="x"))) == [0]


def reader(path: str, p: str = "r") -> str:
    """Open path, read it 7 trytes at a time, and exit with the sum of its
    trytes, or with open's failure. Labels start with p."""
    return f"""
        CALL_FS
        li    a2, FS_OPEN
        la    a3, {p}path
        li    a4, O_RDONLY
        sys
        bltz  a0, 9f
        mv    s2, a0                   # s2: the descriptor
        li    s1, 0                    # s1: the sum of what it read
1:      li    a0, SYS_READ
        mv    a1, s2
        la    a2, {p}buf
        li    a3, 7
        sys
        blez  a0, 3f
        la    t0, {p}buf
        add   t1, t0, a0
2:      lt    t2, 0(t0)
        add   s1, s1, t2
        addi  t0, t0, 1
        blt   t0, t1, 2b
        j     1b
3:      mv    a0, s1
9:      mv    a1, a0
        li    a0, SYS_EXIT
        sys
{p}path: .string "{path}"
{p}buf: .zero 7
"""


def test_two_processes_read_files_at_once():
    a = "".join(chr(33 + i % 90) for i in range(PAGE + 300))
    b = "".join(chr(40 + i % 50) for i in range(2 * PAGE + 7))
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
    result = run(
        init,
        reader("/d/a", "a"),
        reader("b", "b"),
        disk=disk(10, dirs=("d",), d__a=a, b=b),
        max_steps=30_000_000,
    )
    sums = sum(map(ord, a)), sum(map(ord, b))
    assert sorted(result.code_of(p) for p in (3, 4)) == sorted(sums)
    assert result.code_of(0) == sum(sums)


def disk_program(body: str) -> list[int]:
    image = _assemble(
        ["-"],
        stdin=f"""
        .include "include/layout.s"
        .section disk, V_USER, V_USER
        .gp   USER_GP
{find_servers(body, 0)}
""",
    )
    return program_file(image.path.read_bytes())


def test_spawnf_starts_a_program_file():
    greet = disk_program("""
        la    a1, msg
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_EXIT
        li    a1, 42
        sys
msg:    .string "hello from a file\\n"
""")
    spawn = """
        CALL_FS
        li    a2, FS_SPAWN
        la    a3, {}
        li    a5, 0
        sys"""
    program = report(
        spawn.format("p") + "\n        mv    s1, a0",
        wait_for("s1") + "\n        mv    a0, a1",
        spawn.format("text"),
        spawn.format("dir"),
        spawn.format("empty"),
        spawn.format("nope"),
        data=string("p", "/bin/greet")
        + string("text", "notes")
        + string("dir", "bin")
        + string("empty", "empty")
        + string("nope", "bin/nope"),
    )
    on = disk(dirs=("bin",), bin__greet=greet, notes="li a0, 4", empty="")
    result = run(program, disk=on)
    assert "hello from a file\n" in result.console
    assert said(result) == [
        3,  # the child: processes 1 and 2 are the servers
        42,
        L["E_NOEXEC"],
        L["E_NOEXEC"],
        L["E_NOEXEC"],
        L["E_NOENT"],
    ]


def test_a_killed_reader_leaves_the_server_usable():
    # A child is killed as soon as it starts, perhaps while the server
    # holds its call; the parent then reads the same file.
    init = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        li    a0, SYS_KILL
        mv    a1, s1
        li    a2, FOR_SELF
        sys
        {wait_for("s1")}
{reader("f", "p")}
"""
    result = run(init, reader("f", "c"), disk=disk(f="q" * 50))
    assert result.code_of(0) == 50 * ord("q")
