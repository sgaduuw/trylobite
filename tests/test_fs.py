"""The filesystem format (docs/filesystem.md) and tools/fs.py, which builds
and reads its images. The kernel reads what the tool writes, so the
tool must agree with the assembler about every number in
include/layout.s; tests/test_files.py has the kernel read the tool's
images."""

import pytest

from tests.kernel import build
from tools import fs
from tools.fs import PAGE, Filesystem, FsError

L = fs.L


def test_the_tool_reads_layout_as_the_assembler_does():
    symbols = build("li a1, 0\n        li a0, SYS_EXIT\n        sys").symbols
    shared = {name: value for name, value in fs.L.items() if name in symbols}
    assert {"FS_MAP", "I_INDIRECT", "D_INO", "DIRENTS", "FS_MAGIC"} <= shared.keys()
    assert shared == {name: symbols[name] for name in shared}


def test_the_numbers_fit_their_blocks():
    # The map runs to block 0's last tryte; the last inode and the last
    # directory entry end within their blocks.
    assert L["FS_MAP"] + L["FS_MAX_BLOCKS"] - 1 == fs.HALF
    last_inode = fs.inode_at(L["FS_INODES"] - 1)
    assert last_inode + L["I_INDIRECT"] == fs.HALF - 1
    last_entry = fs.entry_at(L["DIRENTS"] - 1)
    assert last_entry + L["D_INO"] + 1 <= fs.HALF
    assert fs.entry_at(L["DIRENTS"]) == fs.entry_at(0)  # the next block's first
    assert L["INODE"] == 3 * (L["NDIRECT"] + 4)


@pytest.mark.parametrize("value", [0, 1, -1, 9841, -9842, 3**26, -(3**27 - 1) // 2])
def test_a_word_splits_into_trytes_and_back(value):
    trytes = fs.split_word(value)
    assert all(-fs.HALF <= t <= fs.HALF for t in trytes)
    assert fs.join_word(trytes) == value


def test_a_new_filesystem_is_a_root_holding_dot_and_dot_dot():
    made = Filesystem.new(3)
    root = made.inode(L["ROOT_INO"])
    assert (root.type, root.links, root.size) == (L["T_DIR"], 2, 2 * L["DIRENT"])
    assert [(e.name, e.ino) for e in made.entries(L["ROOT_INO"])] == [
        (".", 1),
        ("..", 1),
    ]
    assert made.free_blocks() == []  # 0, the inodes, and the root's block


def test_files_and_directories_survive_a_save_and_a_load(tmp_path):
    image = tmp_path / "disk.img"
    long = "ternary " * 3000  # 24,000 trytes: two blocks
    made = Filesystem.new(10)
    made.write("notes", "kept on a ternary disk\n")
    made.mkdir("docs")
    made.write("/docs/long", long)
    made.write("docs/empty", "")
    made.save(image)
    assert image.stat().st_size == 10 * PAGE * 2

    again = Filesystem.load(image)
    assert [(n, i.size) for n, i in again.listdir()] == [("notes", 23), ("docs", 84)]
    assert [(n, i.size) for n, i in again.listdir("docs")] == [
        ("long", 24000),
        ("empty", 0),
    ]
    assert again.read("notes") == "kept on a ternary disk\n"
    assert again.read("//docs/long") == long
    assert again.read("docs/empty") == ""
    assert again.inode(again.lookup("docs")).links == 2
    assert again.inode(again.lookup("/")).links == 3  # ., .. and docs/..
    assert again.free_blocks() == [7, 8, 9]


def test_a_big_file_takes_an_indirect_block():
    made = Filesystem.new(12)
    text = "z" * (L["NDIRECT"] * PAGE + 7)
    made.write("big", text)
    node = made.inode(made.lookup("big"))
    assert all(node.direct) and node.indirect
    assert len(made.block_list(node)) == L["NDIRECT"] + 1
    assert made.read("big") == text
    assert len(made.free_blocks()) == 12 - 3 - (L["NDIRECT"] + 2)
    made.remove("big")
    assert len(made.free_blocks()) == 12 - 3


def test_replacing_and_removing_give_blocks_back():
    made = Filesystem.new(6)
    made.write("a", "x" * (2 * PAGE))
    assert made.free_blocks() == [5]
    made.write("a", "short")
    assert made.free_blocks() == [4, 5]
    assert made.read("a") == "short"
    made.remove("a")
    assert made.free_blocks() == [3, 4, 5]
    assert made.listdir() == []


def test_a_full_disk_refuses_without_losing_the_old_file():
    made = Filesystem.new(5)
    made.write("a", "first")
    with pytest.raises(FsError, match="no room"):
        made.write("a", "x" * (3 * PAGE))
    assert made.read("a") == "first"
    made.write("a", "x" * (2 * PAGE))  # its own block counts as room
    assert made.free_blocks() == []
    with pytest.raises(FsError, match="no room"):
        made.write("b", "y")
    assert [n for n, _ in made.listdir()] == ["a"]


def test_inodes_run_out():
    made = Filesystem.new(4)
    for i in range(L["FS_INODES"] - 2):  # 0 is never used, 1 is the root
        made.write(f"f{i}", "")
    with pytest.raises(FsError, match="no free inode"):
        made.write("more", "")
    made.check()


def test_a_directory_holds_one_block_of_entries():
    made = Filesystem.new(4)
    made.write("f", "")
    for i in range(L["DIRENTS"] - 3):
        made.add_entry(L["ROOT_INO"], f"n{i}", 2)  # more names than inodes
    with pytest.raises(FsError, match="directory is full"):
        made.add_entry(L["ROOT_INO"], "more", 2)


def test_removing_a_directory_needs_it_empty():
    made = Filesystem.new(6)
    made.mkdir("d")
    made.write("d/f", "x")
    with pytest.raises(FsError, match="not empty"):
        made.remove("d")
    made.remove("d/f")
    made.remove("d")
    assert made.free_blocks() == [3, 4, 5]
    assert made.inode(1).links == 2


def test_paths_must_lead_somewhere():
    made = Filesystem.new(6)
    made.write("f", "x")
    with pytest.raises(FsError, match="no such directory"):
        made.write("nope/g", "y")
    with pytest.raises(FsError, match="no such directory"):
        made.write("f/g", "y")
    with pytest.raises(FsError, match="already there"):
        made.mkdir("f")
    with pytest.raises(FsError, match="a path has at most"):
        made.mkdir("/".join(["d" * 17] * 14))  # 251 characters
    assert made.lookup("f/x") is None
    assert made.lookup("/./f") == made.lookup("f")


@pytest.mark.parametrize(
    "name", ["", "x" * 18, "two words", "tab\t", "a/b", ".", "..", "山" * 2]
)
def test_names_are_checked(name):
    made = Filesystem.new(3)
    with pytest.raises(FsError):
        made.write(name, "")


def test_a_name_may_use_all_seventeen_trytes():
    made = Filesystem.new(4)
    made.write("x" * 17, "full")
    assert made.read("x" * 17) == "full"


def test_a_blank_disk_is_not_a_filesystem(tmp_path):
    image = tmp_path / "blank.img"
    image.write_bytes(bytes(4 * PAGE * 2))
    with pytest.raises(FsError, match="not a trylobite filesystem"):
        Filesystem.load(image)


def test_damage_is_noticed():
    made = Filesystem.new(6)
    made.write("a", "x" * (2 * PAGE))
    made.set_used(5, True)
    with pytest.raises(FsError, match="block 5 is marked used"):
        Filesystem(made.blocks)
    made.set_used(5, False)
    node = made.inode(made.lookup("a"))
    node.direct[1] = node.direct[0]
    made.put_inode(node)
    with pytest.raises(FsError, match="also"):
        Filesystem(made.blocks)
    node.direct[1] = 4
    node.links = 2
    made.put_inode(node)
    with pytest.raises(FsError, match="2 links, not 1"):
        Filesystem(made.blocks)


def test_the_command_line(tmp_path, capsys):
    note = tmp_path / "note"
    note.write_text("hello, disk\n")
    image = tmp_path / "disk.img"
    assert fs.main(["new", str(image), "8", str(note)]) == 0
    assert fs.main(["mkdir", str(image), "docs"]) == 0
    assert fs.main(["put", str(image), str(note), "docs"]) == 0
    assert fs.main(["put", str(image), str(note), "/docs/copy"]) == 0
    assert fs.main(["rm", str(image), "note"]) == 0
    capsys.readouterr()
    assert fs.main(["ls", str(image)]) == 0
    assert capsys.readouterr().out == "         docs/\n"
    assert fs.main(["ls", str(image), "docs"]) == 0
    assert capsys.readouterr().out == "      12 note\n      12 copy\n"
    assert fs.main(["cat", str(image), "docs/copy"]) == 0
    assert capsys.readouterr().out == "hello, disk\n"
    assert fs.main(["cat", str(image), "note"]) == 1
    assert "no such file: note" in capsys.readouterr().err
    assert fs.main(["rm", str(image), "docs"]) == 1
    assert "not empty" in capsys.readouterr().err
