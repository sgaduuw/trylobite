"""The filesystem format (docs/filesystem.md) and tools/fs.py, which builds
and reads its images through tools/rust/tryfs, the host's disk tool, on
lib/rust/tryfs, the code the file server runs. The tool must agree with
the assembler about every number in include/layout.s;
tests/test_files.py has the kernel read the tool's images. The format's
own tests (the tree, transactions, fsck) are the crate's: cargo test
--features std in lib/rust/tryfs."""

import pytest

from tests.kernel import build
from tools import fs
from tools.fs import PAGE, Filesystem, FsError

L = fs.L


def test_the_tool_reads_layout_as_the_assembler_does():
    symbols = build("li a1, 0\n        li a0, SYS_EXIT\n        sys").symbols
    shared = {name: value for name, value in fs.L.items() if name in symbols}
    assert {"FS_MAGIC", "SB_ROOT", "K_EXTENT", "IN_MTIME", "NAME_MAX"} <= shared.keys()
    assert shared == {name: symbols[name] for name in shared}


def test_the_numbers_fit_their_blocks():
    # A directory entry's key is its directory, its kind and its name,
    # three code points to a word; the superblock's words follow the boot
    # record; an inode's last word is its parent.
    assert L["KEY_MAX"] == 2 + L["NAME_WORDS"]
    assert 3 * L["NAME_WORDS"] >= L["NAME_MAX"]
    assert L["BOOT_ENTRY"] < L["BLOCK_W0"] + 3 * L["SB_ROOT"]
    assert L["SB_SUM"] < L["SB_WORDS"]
    assert L["IN_PARENT"] == L["INODE_WORDS"] - 1


@pytest.mark.parametrize("value", [0, 1, -1, 9841, -9842, 3**26, -(3**27 - 1) // 2])
def test_a_word_splits_into_trytes_and_back(value):
    trytes = fs.split_word(value)
    assert all(-fs.HALF <= t <= fs.HALF for t in trytes)
    assert fs.join_word(trytes) == value


def test_a_new_filesystem_is_an_empty_root():
    made = Filesystem.new(3)
    root = made.inode(L["ROOT_INO"])
    assert (root.type, root.links, root.size) == (L["T_DIR"], 2, 2)  # . and ..
    assert (root.mode, root.parent) == (L["MODE_DIR"], L["ROOT_INO"])
    assert made.listdir() == []
    assert made.free_blocks() == [2]  # the superblock and the tree's leaf
    info = made.info()
    assert (info["blocks"], info["inodes"], info["boot"]) == (3, 1, None)


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
    # In name order: a directory reads sorted, as its keys are.
    assert [(n, i.size) for n, i in again.listdir()] == [("docs", 4), ("notes", 23)]
    assert [(n, i.size) for n, i in again.listdir("docs")] == [
        ("empty", 0),
        ("long", 24000),
    ]
    assert again.read("notes") == "kept on a ternary disk\n"
    assert again.read("//docs/long") == long
    assert again.read("docs/empty") == ""
    assert again.inode(again.lookup("docs")).links == 2
    assert again.inode(again.lookup("/")).links == 3  # ., .. and docs/..
    assert again.stat("docs/long").blocks == 2
    assert again.stat("docs/empty").blocks == 0


def test_files_carry_their_metadata():
    made = Filesystem.new(6)
    made.write("f", "x")
    node = made.stat("f")
    assert (node.type, node.mode, node.uid, node.gid) == (L["T_FILE"], L["MODE_FILE"], 0, 0)
    assert node.btime == node.mtime == node.ctime
    made.chmod("f", 0o600)
    made.chown("f", 5, 7)
    made.utimes("f", 1000, 2000)
    node = made.stat("f")
    assert (node.mode, node.uid, node.gid) == (0o600, 5, 7)
    assert (node.atime.secs, node.mtime.secs) == (1000, 2000)
    assert node.ctime.secs > 2000  # now: the change itself


def test_a_big_file_is_one_extent():
    made = Filesystem.new(12)
    text = "z" * (5 * PAGE + 7)
    made.write("big", text)
    node = made.stat("big")
    first = node.data[0]
    assert node.data == list(range(first, first + 6))  # side by side
    assert made.read("big") == text
    free = len(made.free_blocks())
    made.remove("big")
    assert len(made.free_blocks()) == free + 6


def test_replacing_and_removing_give_blocks_back():
    made = Filesystem.new(6)
    free = len(made.free_blocks())
    made.write("a", "x" * (2 * PAGE))
    assert len(made.free_blocks()) == free - 2
    made.write("a", "short")
    assert len(made.free_blocks()) == free - 1
    assert made.read("a") == "short"
    made.remove("a")
    assert len(made.free_blocks()) == free
    assert made.listdir() == []


def test_a_full_disk_refuses_without_losing_the_old_file():
    made = Filesystem.new(5)
    made.write("a", "first")
    with pytest.raises(FsError, match="no space left"):
        made.write("b", "x" * (4 * PAGE))
    assert made.read("a") == "first"
    assert [n for n, _ in made.listdir()] == ["a"]
    made.check()


def test_a_directory_holds_many_entries():
    # Entries are the tree's items, so a directory grows past a block,
    # the tree splitting its leaves.
    made = Filesystem.new(12)
    names = [f"file-{i:03}" for i in range(400)]
    for name in names:
        made.write_trytes(name, [])
    assert [n for n, _ in made.listdir()] == names
    assert made.inode(L["ROOT_INO"]).size == 2 + 400
    made.check()


def test_removing_a_directory_needs_it_empty():
    made = Filesystem.new(6)
    free = len(made.free_blocks())
    made.mkdir("d")
    made.write("d/f", "x")
    with pytest.raises(FsError, match="not empty"):
        made.remove("d")
    made.remove("d/f")
    made.remove("d")
    assert len(made.free_blocks()) == free
    assert made.inode(L["ROOT_INO"]).links == 2


def test_renaming_moves_a_name():
    made = Filesystem.new(6)
    made.mkdir("d")
    made.write("f", "x")
    made.rename("f", "d/g")
    assert made.lookup("f") is None
    assert made.read("d/g") == "x"
    made.rename("d", "e")
    assert made.read("e/g") == "x"
    assert made.stat("e").parent == L["ROOT_INO"]


def test_paths_must_lead_somewhere():
    made = Filesystem.new(6)
    made.write("f", "x")
    with pytest.raises(FsError, match="no such file or directory"):
        made.write("nope/g", "y")
    with pytest.raises(FsError, match="not a directory"):
        made.write("f/g", "y")
    with pytest.raises(FsError, match="exists"):
        made.mkdir("f")
    with pytest.raises(FsError, match="name too long"):
        made.mkdir("/".join(["d" * 17] * 14))  # 251 characters: past PATH_MAX
    assert made.lookup("f/x") is None
    assert made.lookup("/./f") == made.lookup("f")


@pytest.mark.parametrize(
    "name", ["x" * (L["NAME_MAX"] + 1), "two words", "tab\t", ".", ".."]
)
def test_names_are_checked(name):
    made = Filesystem.new(3)
    with pytest.raises(FsError):
        made.write(name, "")


def test_a_name_may_use_all_its_room():
    made = Filesystem.new(4)
    name = "x" * L["NAME_MAX"]
    made.write(name, "full")
    assert made.read(name) == "full"
    assert made.listdir()[0][0] == name


def test_a_blank_disk_is_not_a_filesystem(tmp_path):
    image = tmp_path / "blank.img"
    image.write_bytes(bytes(4 * PAGE * 2))
    with pytest.raises(FsError, match="no filesystem"):
        Filesystem.load(image)


def test_damage_is_noticed(tmp_path):
    made = Filesystem.new(6)
    made.write("a", "x" * (2 * PAGE))
    image = tmp_path / "disk.img"
    made.save(image)
    good = made.raw()
    root = made.info()["root"]

    # A node whose sum does not match what it holds.
    blocks = made.raw()
    word = L["BLOCK_W0"] + 3 * (L["N_ITEMS"] + 2)  # the first item's key
    blocks[root].set_word(word, blocks[root].word(word) + 1)
    made.set_raw(blocks)
    made.save(image)
    with pytest.raises(FsError, match="damaged"):
        Filesystem.load(image)

    # A superblock whose sum does not match.
    blocks = [fs.Block(list(b.trytes)) for b in good]
    at = L["BLOCK_W0"] + 3 * L["SB_NEXT_INO"]
    blocks[0].set_word(at, blocks[0].word(at) + 1)
    made.set_raw(blocks)
    made.save(image)
    with pytest.raises(FsError, match="damaged"):
        Filesystem.load(image)


def test_the_command_line(tmp_path, capsys):
    note = tmp_path / "note"
    note.write_text("hello, disk\n")
    image = tmp_path / "disk.img"
    assert fs.main(["new", str(image), "8", str(note)]) == 0
    assert fs.main(["mkdir", str(image), "docs"]) == 0
    assert fs.main(["put", str(image), str(note), "docs"]) == 0
    assert fs.main(["put", str(image), str(note), "/docs/copy"]) == 0
    assert fs.main(["rm", str(image), "note"]) == 0
    assert fs.main(["check", str(image)]) == 0
    capsys.readouterr()
    assert fs.main(["ls", str(image)]) == 0
    assert capsys.readouterr().out == "         docs/\n"
    assert fs.main(["ls", str(image), "docs"]) == 0
    assert capsys.readouterr().out == "      12 copy\n      12 note\n"
    assert fs.main(["cat", str(image), "docs/copy"]) == 0
    assert capsys.readouterr().out == "hello, disk\n"
    assert fs.main(["cat", str(image), "note"]) == 1
    assert "no such file or directory" in capsys.readouterr().err
    assert fs.main(["rm", str(image), "docs"]) == 1
    assert "not empty" in capsys.readouterr().err


# --- the kernel to boot (block 0's boot record) ------------------------------


def pages(*numbers: int) -> list[fs.Block]:
    """Blocks standing for kernel pages, each filled with its number."""
    return [fs.Block([n] * PAGE) for n in numbers]


def test_a_kernel_goes_in_free_blocks_that_the_boot_record_names(tmp_path):
    made = Filesystem.new(12)
    made.write("a", "x")
    made.set_boot(pages(1, 2, 3))
    boot = made.boot_blocks()
    assert len(boot) == 3
    head = made.raw()[0]
    assert head.word(L["FS_HEAD_BOOT"]) == L["BOOT_MAGIC"]
    assert [head.word(L[k]) for k in ("BOOT_PAGE", "BOOT_ENTRY")] == [1, L["FW_BOOT"]]
    assert [made.raw()[b].trytes[0] for b in boot] == [1, 2, 3]
    made.write("b", "y" * (3 * PAGE))  # files go around it
    assert not set(made.stat("b").data) & set(boot)
    image = tmp_path / "disk.img"
    made.save(image)
    assert Filesystem.load(image).boot_blocks() == boot  # and the check passes


def test_the_record_sits_between_the_header_and_the_superblock():
    words = [L[k] for k in ("FS_HEAD_BOOT", "BOOT_FIRST", "BOOT_COUNT", "BOOT_PAGE")]
    words.append(L["BOOT_ENTRY"])
    # detrytus docs/platform.md, Booting from a disk: words 3 to 7 of block 0
    assert words == [L["BLOCK_W0"] + 3 * w for w in range(3, 8)]
    assert L["FS_HEAD_BLOCKS"] < L["FS_HEAD_BOOT"]


def test_a_new_kernel_replaces_the_old_one():
    made = Filesystem.new(12)
    free = len(made.free_blocks())
    made.set_boot(pages(1, 2))
    assert len(made.free_blocks()) == free - 2
    made.set_boot(pages(1, 2, 3, 4))
    assert len(made.boot_blocks()) == 4
    assert len(made.free_blocks()) == free - 4  # the old blocks were free again
    made.set_boot(pages(1))
    assert len(made.free_blocks()) == free - 1


def test_a_kernel_needs_a_free_run_of_blocks():
    made = Filesystem.new(6)
    made.write("a", "x")
    made.write("b", "x")
    made.remove("a")
    free = made.free_blocks()
    run = max(
        len(range(i, j))
        for i in free
        for j in range(i + 1, 7)
        if all(b in free for b in range(i, j))
    )
    with pytest.raises(FsError, match="no space left"):
        made.set_boot(pages(*range(1, run + 2)))
    made.set_boot(pages(*range(1, run + 1)))
    assert len(made.boot_blocks()) == run


def test_a_kernel_image_is_its_ram_pages_from_page_1():
    image = build("li a1, 0\n        li a0, SYS_EXIT\n        sys")
    blocks = fs.boot_image(image.path.read_bytes())
    last = max((a + PAGE // 2) // PAGE for a in image.trytes)
    assert len(blocks) == last
    filled = {a for a in image.trytes if a > PAGE // 2}  # the boot page stays out
    in_blocks = {
        p * PAGE + i - PAGE // 2
        for p, block in enumerate(blocks, 1)
        for i, t in enumerate(block.trytes)
        if t
    }
    assert in_blocks <= filled
    # A device page is refused.
    with pytest.raises(FsError, match="device page -1"):
        fs.boot_image(fake_dti(-PAGE, [5]))


def fake_dti(start: int, trytes: list[int]) -> bytes:
    """A .dti image of one segment, with empty metadata."""
    import struct

    trits = []
    for t in trytes:
        for _ in range(9):
            r = (t + 1) % 3 - 1
            trits.append(r)
            t = (t - r) // 3
    trits += [0] * (-len(trits) % 5)
    data = bytes(
        sum((trits[i + k] + 1) * 3**k for k in range(5))
        for i in range(0, len(trits), 5)
    )
    return (
        fs.DTI_MAGIC
        + struct.pack("<I", 2)
        + b"{}"
        + struct.pack("<I", 1)
        + struct.pack("<qI", start, len(trytes))
        + data
    )
