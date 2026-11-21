"""The filesystem format (docs/filesystem.md) and tools/fs.py, which builds
and reads its images. Programs on the machine and the tool must agree on
every offset, so two tests cross the boundary: a program reads a file the
tool wrote, and the tool reads one a program wrote."""

import pytest

from tests.kernel import build, exit_with, new_disk, run
from tools import fs
from tools.fs import PAGE, Filesystem, FsError


def test_the_tool_reads_layout_as_the_assembler_does():
    symbols = build("li a1, 0\n        li a0, SYS_EXIT\n        sys").symbols
    shared = {name: value for name, value in fs.L.items() if name in symbols}
    assert {"FS_FAT", "DE_NAME", "FS_MAGIC", "FAT_END"} <= shared.keys()
    assert shared == {name: symbols[name] for name in shared}


def test_the_fat_fills_block_0_exactly():
    last = fs.L["FS_FAT"] + 3 * (fs.L["FS_MAX_BLOCKS"] - 1)
    assert last == fs.HALF - 1  # the last word of the block
    directory_end = fs.entry_at(fs.L["FS_FILES"]) - 3
    assert directory_end < fs.L["FS_FAT"]


@pytest.mark.parametrize("value", [0, 1, -1, 9841, -9842, 3**26, -(3**27 - 1) // 2])
def test_a_word_splits_into_trytes_and_back(value):
    trytes = fs.split_word(value)
    assert all(-fs.HALF <= t <= fs.HALF for t in trytes)
    assert fs.join_word(trytes) == value


def test_files_survive_a_save_and_a_load(tmp_path):
    image = tmp_path / "disk.img"
    long = "ternary " * 3000  # 24,000 trytes: two blocks
    made = Filesystem.new(8)
    made.write("notes", "kept on a ternary disk\n")
    made.write("long", long)
    made.write("empty", "")
    made.save(image)
    assert image.stat().st_size == 8 * PAGE * 2

    fs_ = Filesystem.load(image)
    assert [(e.name, e.size) for e in fs_.entries()] == [
        ("notes", 23),
        ("long", 24000),
        ("empty", 0),
    ]
    assert fs_.read("notes") == "kept on a ternary disk\n"
    assert fs_.read("long") == long
    assert fs_.read("empty") == ""
    assert fs_.find("empty").first == fs.L["FAT_END"]
    assert fs_.free_blocks() == [4, 5, 6, 7]


def test_replacing_and_removing_give_blocks_back():
    made = Filesystem.new(4)
    made.write("a", "x" * (2 * PAGE))
    assert made.free_blocks() == [3]
    made.write("a", "short")
    assert made.free_blocks() == [2, 3]
    assert made.read("a") == "short"
    made.remove("a")
    assert made.free_blocks() == [1, 2, 3]
    assert made.entries() == []


def test_a_full_disk_refuses_without_losing_the_old_file():
    made = Filesystem.new(3)
    made.write("a", "first")
    with pytest.raises(FsError, match="no room"):
        made.write("a", "x" * (3 * PAGE))
    assert made.read("a") == "first"
    made.write("a", "x" * (2 * PAGE))  # its own block counts as room
    assert made.free_blocks() == []


def test_the_directory_holds_a_fixed_number_of_files():
    made = Filesystem.new(fs.L["FS_FILES"] + 2)
    for i in range(fs.L["FS_FILES"]):
        made.write(f"f{i}", "")
    with pytest.raises(FsError, match="directory is full"):
        made.write("more", "")


@pytest.mark.parametrize("name", ["", "x" * 18, "two words", "tab\t", "山" * 2])
def test_names_are_checked(name):
    made = Filesystem.new(2)
    if name == "山" * 2:  # above 9,841: not a tryte
        with pytest.raises(FsError):
            made.write(name, "")
        return
    with pytest.raises(FsError, match="a name"):
        made.write(name, "")


def test_a_name_may_use_all_seventeen_trytes():
    made = Filesystem.new(2)
    made.write("x" * 17, "full")
    assert made.read("x" * 17) == "full"


def test_a_blank_disk_is_not_a_filesystem(tmp_path):
    image = tmp_path / "blank.img"
    image.write_bytes(bytes(4 * PAGE * 2))
    with pytest.raises(FsError, match="not a trylobite filesystem"):
        Filesystem.load(image)


def test_a_broken_chain_is_noticed():
    made = Filesystem.new(4)
    made.write("a", "x" * (2 * PAGE))
    made.set_fat(1, 1)  # a cycle
    with pytest.raises(FsError, match="broken chain"):
        Filesystem(made.blocks)


def test_the_command_line(tmp_path, capsys):
    note = tmp_path / "note"
    note.write_text("hello, disk\n")
    image = tmp_path / "disk.img"
    assert fs.main(["new", str(image), "4", str(note)]) == 0
    assert fs.main(["put", str(image), str(note), "copy"]) == 0
    assert fs.main(["rm", str(image), "note"]) == 0
    capsys.readouterr()
    assert fs.main(["ls", str(image)]) == 0
    assert capsys.readouterr().out == "      12 copy\n"
    assert fs.main(["cat", str(image), "copy"]) == 0
    assert capsys.readouterr().out == "hello, disk\n"
    assert fs.main(["cat", str(image), "note"]) == 1
    assert "no such file: note" in capsys.readouterr().err


# A program reads directory entry 0, prints its name, then its text.
READ_ENTRY_0 = f"""
        li    a0, SYS_BREAD
        li    a1, 0
        sys
        bnez  a0, 9f
        li    s0, V_BLOCK
        lw    t0, FS_HEAD_MAGIC(s0)
        li    t1, FS_MAGIC
        li    a0, 1
        bne   t0, t1, 9f
        li    a0, SYS_PUTS
        li    a1, V_BLOCK + FS_DIR + DE_NAME
        sys
        lw    s1, FS_DIR + DE_SIZE(s0)
        lw    a1, FS_DIR + DE_FIRST(s0)
        li    a0, SYS_BREAD
        sys
        bnez  a0, 9f
        add   t0, s0, s1               # end the text after its size
        st    zero, BLOCK_T0(t0)
        li    a0, SYS_PUTS
        li    a1, V_BLOCK + BLOCK_T0
        sys
9:      {exit_with("a0")}
"""


def test_a_program_reads_a_file_the_tool_wrote():
    image = new_disk()
    made = Filesystem.new(4)
    made.write("a", "x" * PAGE)  # so the file below starts at block 2
    made.remove("a")
    made.write("motd", ":welcome to the disk:")
    made.save(image)
    result = run(READ_ENTRY_0, disk=(image, 4))
    assert result.code_of(0) == 0
    assert "motd:welcome to the disk:" in result.console


# A program makes file "made" in entry 0, with its text in block 1.
WRITE_FILE = f"""
        li    a0, SYS_BREAD
        li    a1, 0
        sys
        bnez  a0, 9f
        li    s0, V_BLOCK
        la    t1, name
        addi  t2, s0, FS_DIR + DE_NAME
1:      lt    t0, 0(t1)
        st    t0, 0(t2)
        addi  t1, t1, 1
        addi  t2, t2, 1
        bnez  t0, 1b
        li    t0, text_end - text
        sw    t0, FS_DIR + DE_SIZE(s0)
        li    t0, 1
        sw    t0, FS_DIR + DE_FIRST(s0)
        li    t0, FAT_END
        sw    t0, FS_FAT + 3(s0)       # block 1 ends its file
        li    a0, SYS_BWRITE
        li    a1, 0
        sys
        bnez  a0, 9f
        la    t1, text
        addi  t2, s0, BLOCK_T0
        la    t3, text_end
2:      lt    t0, 0(t1)
        st    t0, 0(t2)
        addi  t1, t1, 1
        addi  t2, t2, 1
        blt   t1, t3, 2b
        li    a0, SYS_BWRITE
        li    a1, 1
        sys
9:      {exit_with("a0")}
name:   .string "made"
text:   .ascii "written on the machine\\n"
text_end:
"""


def test_the_tool_reads_a_file_a_program_wrote():
    image = new_disk()
    Filesystem.new(3).save(image)
    assert run(WRITE_FILE, disk=(image, 3)).code_of(0) == 0
    assert Filesystem.load(image).read("made") == "written on the machine\n"
