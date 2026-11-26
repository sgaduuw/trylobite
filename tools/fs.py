#!/usr/bin/env python3
"""Build and read trylobite filesystem images (docs/filesystem.md).

    tools/fs.py new IMAGE BLOCKS [FILE ...]   a new filesystem, with files
    tools/fs.py ls IMAGE [PATH]               a directory's files and sizes
    tools/fs.py cat IMAGE PATH                a file's text, to stdout
    tools/fs.py put IMAGE FILE [PATH]         add a file, or replace it
    tools/fs.py mkdir IMAGE PATH              make a directory
    tools/fs.py rm IMAGE PATH                 remove a file or empty directory

A file is text, each code point one tryte between 1 and 9,841, or a
program: `put` given an image assembled by `detrytus asm` (a .dti file)
stores it as a program file in /bin, where the shell finds it, and
given a .s file assembles it first, or a Trice .tc file builds it
first, linked with the .tc files it imports, or a Rust .rs file builds
it with cargo and `detrytus ll` (docs/rust.md) (with $DETRYTUS, or
detrytus on the PATH). Paths start at the
root, with or without a leading slash. The image is a detrytus disk
file, two bytes per tryte, so `detrytus run --disk IMAGE` attaches it.
The format's numbers are read from
include/layout.s, which the kernel and programs share.
"""

from __future__ import annotations

import argparse
import ast
import contextlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

LAYOUT = Path(__file__).resolve().parent.parent / "include" / "layout.s"


_OPS = {ast.Add: int.__add__, ast.Sub: int.__sub__, ast.Mult: int.__mul__}


def _value(node: ast.AST, names: dict[str, int]) -> int:
    """An expression of numbers, known names, + - * and parentheses."""
    match node:
        case ast.Constant(value=int(n)):
            return n
        case ast.Name(id=name) if name in names:
            return names[name]
        case ast.UnaryOp(op=ast.USub(), operand=x):
            return -_value(x, names)
        case ast.BinOp(left=a, op=op, right=b) if type(op) in _OPS:
            return _OPS[type(op)](_value(a, names), _value(b, names))
    raise ValueError


def _equates(path: Path) -> dict[str, int]:
    """Every `.equ NAME, EXPR` in a file that _value can work out."""
    values: dict[str, int] = {}
    for line in path.read_text().splitlines():
        m = re.match(r"\s*\.equ\s+(\w+)\s*,\s*([^#]+)", line)
        if not m:
            continue
        # One that needs a name from the build, such as NPROG, is not ours.
        with contextlib.suppress(SyntaxError, ValueError):
            expr = ast.parse(m.group(2).strip(), mode="eval").body
            values[m.group(1)] = _value(expr, values)
    return values


L = _equates(LAYOUT)
PAGE = L["PAGE"]
HALF = PAGE // 2  # 9841: the largest tryte, and a block's last offset
TRYTE_BYTES = 2
BLOCK_BYTES = PAGE * TRYTE_BYTES
DTI_MAGIC = b"DTI\x01"


class FsError(Exception):
    """The image is not a filesystem, or cannot do what was asked."""


# --- trytes and words ------------------------------------------------------------


def split_word(value: int) -> list[int]:
    """A word's three trytes, low first (detrytus isa.md 5.2)."""
    trytes = []
    for _ in range(3):
        low = (value + HALF) % PAGE - HALF
        trytes.append(low)
        value = (value - low) // PAGE
    if value:
        raise FsError(f"{value} does not fit in a word")
    return trytes


def join_word(trytes: list[int]) -> int:
    return trytes[0] + PAGE * (trytes[1] + PAGE * trytes[2])


@dataclass
class Block:
    """One block's trytes, reached by offset from its centre."""

    trytes: list[int]

    @classmethod
    def blank(cls) -> Block:
        return cls([0] * PAGE)

    def tryte(self, offset: int) -> int:
        return self.trytes[offset + HALF]

    def set_tryte(self, offset: int, value: int) -> None:
        if not -HALF <= value <= HALF:
            raise FsError(f"{value} does not fit in a tryte")
        self.trytes[offset + HALF] = value

    def word(self, offset: int) -> int:
        assert offset % 3 == 0, "words are aligned"
        i = offset + HALF
        return join_word(self.trytes[i - 1 : i + 2])

    def set_word(self, offset: int, value: int) -> None:
        assert offset % 3 == 0, "words are aligned"
        i = offset + HALF
        self.trytes[i - 1 : i + 2] = split_word(value)


# --- programs ---------------------------------------------------------------------


def read_dti(data: bytes) -> list[tuple[int, list[int]]]:
    """The segments of a detrytus image (.dti): each one's first address
    and its trytes. Five trits to a byte, least significant first, each
    byte sum((trit + 1) * 3^i); nine trits to a tryte."""
    if data[:4] != DTI_MAGIC:
        raise FsError("not a detrytus image")
    (meta_len,) = struct.unpack_from("<I", data, 4)
    pos = 8 + meta_len
    (count,) = struct.unpack_from("<I", data, pos)
    pos += 4
    segments = []
    for _ in range(count):
        start, n = struct.unpack_from("<qI", data, pos)
        pos += 12
        size = -(-9 * n // 5)
        trits = []
        for byte in data[pos : pos + size]:
            for _ in range(5):
                trits.append(byte % 3 - 1)
                byte //= 3
        pos += size
        trytes = [
            sum(t * 3**i for i, t in enumerate(trits[9 * k : 9 * k + 9]))
            for k in range(n)
        ]
        segments.append((start, trytes))
    return segments


def program_file(data: bytes) -> list[int]:
    """A program file's trytes, from an assembled image: EXEC_MAGIC, the
    image's size, then the image, from V_USER - 1 to its last tryte, with
    any gap between its segments zero. It must be assembled to load where
    it runs, and have at most EXEC_MAX trytes from V_USER - 1."""
    low, high = L["V_USER"] - 1, L["V_USER"] - 1 + L["EXEC_MAX"]
    image: list[int] = []
    for start, trytes in read_dti(data):
        if not low <= start <= start + len(trytes) <= high:
            raise FsError(
                f"a program loads and runs from V_USER ({L['V_USER']}) and has "
                f"at most {L['EXEC_MAX']} trytes, but fills {start} to "
                f"{start + len(trytes) - 1}"
            )
        at = start - low
        image += [0] * (at + len(trytes) - len(image))
        image[at : at + len(trytes)] = trytes
    return split_word(L["EXEC_MAGIC"]) + split_word(len(image)) + image


def is_program(trytes: list[int]) -> bool:
    return len(trytes) >= L["EXEC_HEAD"] and join_word(trytes[:3]) == L["EXEC_MAGIC"]


# --- the disk file -------------------------------------------------------------


def read_blocks(path: Path) -> list[Block]:
    """Every block of a disk file; a short last block is padded with zeros,
    as the emulator reads it."""
    data = path.read_bytes()
    data += bytes(-len(data) % BLOCK_BYTES)
    values = struct.unpack(f"<{len(data) // 2}h", data)
    return [Block(list(values[i : i + PAGE])) for i in range(0, len(values), PAGE)]


def write_blocks(path: Path, blocks: list[Block]) -> None:
    out = bytearray()
    for block in blocks:
        out += struct.pack(f"<{PAGE}h", *block.trytes)
    path.write_bytes(bytes(out))


# --- the filesystem --------------------------------------------------------------


@dataclass
class Inode:
    number: int
    type: int
    links: int
    size: int
    direct: list[int]
    indirect: int


@dataclass
class Entry:
    """A directory entry: the name and the inode it names."""

    name: str
    ino: int


def check_name(name: str) -> None:
    if not 1 <= len(name) <= L["NAME_MAX"]:
        raise FsError(f"a name is 1 to {L['NAME_MAX']} characters: {name!r}")
    if any(ord(c) <= ord(" ") or ord(c) > HALF or c == "/" for c in name):
        raise FsError(f"a name has no spaces, slashes or control characters: {name!r}")
    if name in (".", ".."):
        raise FsError(f"{name!r} is taken by every directory")


def check_text(text: str, what: str) -> None:
    for c in text:
        if not 1 <= ord(c) <= HALF:
            raise FsError(f"{what}: code point {ord(c)} does not fit in a tryte")


def split_path(path: str) -> list[str]:
    """A path's names. It starts at the root whether or not it starts with
    a slash, since nothing has a current directory yet."""
    return [name for name in path.split("/") if name]


def inode_at(number: int) -> int:
    return L["BLOCK_W0"] + L["INODE"] * number


def entry_at(slot: int) -> int:
    """The offset of entry slot of a directory, within its block."""
    return L["BLOCK_W0"] + L["DIRENT"] * (slot % L["DIRENTS"])


def blocks_for(size: int) -> int:
    """Data blocks for a file of size trytes."""
    return -(-size // PAGE)


def room_for(size: int) -> int:
    """Blocks a file of size trytes takes: its data, and an indirect block
    once it has more than NDIRECT."""
    n = blocks_for(size)
    return n + (n > L["NDIRECT"])


class Filesystem:
    """A filesystem image, held in memory: change it, then save it."""

    def __init__(self, blocks: list[Block]):
        self.blocks = blocks
        head = blocks[0] if blocks else Block.blank()
        if head.word(L["FS_HEAD_MAGIC"]) != L["FS_MAGIC"]:
            raise FsError("not a trylobite filesystem")
        version = head.word(L["FS_HEAD_VERSION"])
        if version != L["FS_VERSION"]:
            raise FsError(f"filesystem version {version}, not {L['FS_VERSION']}")
        self.count = head.word(L["FS_HEAD_BLOCKS"])
        if not 3 <= self.count <= min(len(blocks), L["FS_MAX_BLOCKS"]):
            raise FsError(f"the header claims {self.count} blocks")
        self.head = head
        self.table = blocks[L["FS_INODE_BLOCK"]]
        self.check()

    @classmethod
    def new(cls, count: int) -> Filesystem:
        if not 3 <= count <= L["FS_MAX_BLOCKS"]:
            raise FsError(f"a filesystem has 3 to {L['FS_MAX_BLOCKS']} blocks")
        blocks = [Block.blank() for _ in range(count)]
        head = blocks[0]
        head.set_word(L["FS_HEAD_MAGIC"], L["FS_MAGIC"])
        head.set_word(L["FS_HEAD_VERSION"], L["FS_VERSION"])
        head.set_word(L["FS_HEAD_BLOCKS"], count)
        for block in (0, L["FS_INODE_BLOCK"]):
            head.set_tryte(L["FS_MAP"] + block, L["MAP_USED"])
        made = object.__new__(cls)
        made.blocks, made.count, made.head = blocks, count, head
        made.table = blocks[L["FS_INODE_BLOCK"]]
        root = L["ROOT_INO"]
        made.put_inode(Inode(root, L["T_DIR"], 2, 0, [0] * L["NDIRECT"], 0))
        made.add_entry(root, ".", root)
        made.add_entry(root, "..", root)
        made.check()
        return made

    @classmethod
    def load(cls, path: Path) -> Filesystem:
        return cls(read_blocks(path))

    def save(self, path: Path) -> None:
        write_blocks(path, self.blocks)

    # --- the map of free blocks

    def used(self, block: int) -> bool:
        return self.head.tryte(L["FS_MAP"] + block) == L["MAP_USED"]

    def set_used(self, block: int, used: bool) -> None:
        self.head.set_tryte(L["FS_MAP"] + block, L["MAP_USED" if used else "MAP_FREE"])

    def free_blocks(self) -> list[int]:
        return [b for b in range(self.count) if not self.used(b)]

    def allocate(self) -> int:
        free = self.free_blocks()
        if not free:
            raise FsError("the disk is full")
        self.set_used(free[0], True)
        self.blocks[free[0]] = Block.blank()
        return free[0]

    # --- inodes

    def inode(self, number: int) -> Inode:
        at = inode_at(number)
        w = self.table.word
        return Inode(
            number,
            w(at + L["I_TYPE"]),
            w(at + L["I_LINKS"]),
            w(at + L["I_SIZE"]),
            [w(at + L["I_DIRECT"] + 3 * k) for k in range(L["NDIRECT"])],
            w(at + L["I_INDIRECT"]),
        )

    def put_inode(self, node: Inode) -> None:
        at = inode_at(node.number)
        s = self.table.set_word
        s(at + L["I_TYPE"], node.type)
        s(at + L["I_LINKS"], node.links)
        s(at + L["I_SIZE"], node.size)
        for k, block in enumerate(node.direct):
            s(at + L["I_DIRECT"] + 3 * k, block)
        s(at + L["I_INDIRECT"], node.indirect)

    def new_inode(self, type_: int) -> Inode:
        for number in range(L["ROOT_INO"] + 1, L["FS_INODES"]):
            if self.inode(number).type == L["T_FREE"]:
                node = Inode(number, type_, 0, 0, [0] * L["NDIRECT"], 0)
                self.put_inode(node)
                return node
        raise FsError("no free inode")

    def block_list(self, node: Inode) -> list[int]:
        """The inode's data block numbers, in order, NO_BLOCK for a hole,
        as many as its size needs."""
        n = blocks_for(node.size)
        found = node.direct[: min(n, L["NDIRECT"])]
        if n > L["NDIRECT"]:
            if node.indirect == L["NO_BLOCK"]:
                found += [L["NO_BLOCK"]] * (n - L["NDIRECT"])
            else:
                table = self.blocks[node.indirect]
                found += [
                    table.word(L["BLOCK_W0"] + 3 * k) for k in range(n - L["NDIRECT"])
                ]
        return found

    def contents(self, node: Inode) -> list[int]:
        trytes: list[int] = []
        for i, block in enumerate(self.block_list(node)):
            n = min(PAGE, node.size - i * PAGE)
            if block == L["NO_BLOCK"]:
                trytes += [0] * n
            else:
                trytes += self.blocks[block].trytes[:n]
        return trytes

    def set_contents(self, node: Inode, trytes: list[int]) -> None:
        """Give the inode these contents, in fresh blocks, freeing its old ones."""
        need = blocks_for(len(trytes))
        if room_for(len(trytes)) > len(self.free_blocks()) + len(self.owned(node)):
            raise FsError(f"no room for {room_for(len(trytes))} blocks")
        if need > L["NDIRECT"] + PAGE // 3:
            raise FsError("too big for one file")
        self.release(node)
        blocks = [self.allocate() for _ in range(need)]
        for i, block in enumerate(blocks):
            chunk = trytes[i * PAGE : (i + 1) * PAGE]
            self.blocks[block].trytes = chunk + [0] * (PAGE - len(chunk))
        node.direct = (blocks + [0] * L["NDIRECT"])[: L["NDIRECT"]]
        node.indirect = L["NO_BLOCK"]
        if need > L["NDIRECT"]:
            node.indirect = self.allocate()
            table = self.blocks[node.indirect]
            for k, block in enumerate(blocks[L["NDIRECT"] :]):
                table.set_word(L["BLOCK_W0"] + 3 * k, block)
        node.size = len(trytes)
        self.put_inode(node)

    def owned(self, node: Inode) -> list[int]:
        """Every block the inode holds: its data and its indirect block."""
        found = [b for b in self.block_list(node) if b != L["NO_BLOCK"]]
        if node.indirect != L["NO_BLOCK"]:
            found.append(node.indirect)
        return found

    def release(self, node: Inode) -> None:
        for block in self.owned(node):
            self.set_used(block, False)
        node.direct = [0] * L["NDIRECT"]
        node.indirect = L["NO_BLOCK"]
        node.size = 0

    # --- directories

    def entries(self, ino: int) -> list[Entry]:
        """A directory's entries, . and .. included, in their order."""
        node = self.inode(ino)
        if node.type != L["T_DIR"]:
            raise FsError(f"inode {ino} is not a directory")
        found = []
        blocks = self.block_list(node)
        for slot in range(node.size // L["DIRENT"]):
            block = blocks[slot // L["DIRENTS"]]
            if block == L["NO_BLOCK"]:
                continue
            data, at = self.blocks[block], entry_at(slot)
            number = data.word(at + L["D_INO"])
            if number == L["NO_INO"]:
                continue
            name = ""
            for i in range(L["NAME_MAX"] + 1):
                c = data.tryte(at + L["D_NAME"] + i)
                if c == 0:
                    break
                name += chr(c) if c > 0 else "?"
            found.append(Entry(name, number))
        return found

    def add_entry(self, dir_ino: int, name: str, ino: int) -> None:
        """Name inode ino in directory dir_ino, in its first unused slot or
        a new one at its end, which may take a new block."""
        node = self.inode(dir_ino)
        slots = node.size // L["DIRENT"]
        blocks = self.block_list(node)
        slot = next(
            (
                s
                for s in range(slots)
                if self.blocks[blocks[s // L["DIRENTS"]]].word(entry_at(s) + L["D_INO"])
                == L["NO_INO"]
            ),
            slots,
        )
        if slot == slots:
            if slot >= L["DIRENTS"]:  # one block, for now
                raise FsError("the directory is full")
            if slot == 0:
                node.direct[0] = self.allocate()
            node.size += L["DIRENT"]
            self.put_inode(node)
        data = self.blocks[self.block_list(node)[slot // L["DIRENTS"]]]
        at = entry_at(slot)
        for i in range(L["NAME_MAX"] + 1):
            data.set_tryte(at + L["D_NAME"] + i, ord(name[i]) if i < len(name) else 0)
        data.set_word(at + L["D_INO"], ino)

    def drop_entry(self, dir_ino: int, name: str) -> None:
        node = self.inode(dir_ino)
        blocks = self.block_list(node)
        for slot, entry in self._slots(node, blocks):
            if entry.name == name:
                data, at = self.blocks[blocks[slot // L["DIRENTS"]]], entry_at(slot)
                for i in range(L["DIRENT"]):
                    data.set_tryte(at + L["D_NAME"] + i, 0)
                return
        raise FsError(f"no such file: {name}")

    def _slots(self, node: Inode, blocks: list[int]):
        for slot in range(node.size // L["DIRENT"]):
            data, at = self.blocks[blocks[slot // L["DIRENTS"]]], entry_at(slot)
            number = data.word(at + L["D_INO"])
            if number != L["NO_INO"]:
                name = ""
                for i in range(L["NAME_MAX"] + 1):
                    c = data.tryte(at + L["D_NAME"] + i)
                    if c == 0:
                        break
                    name += chr(c)
                yield slot, Entry(name, number)

    # --- paths

    def lookup(self, path: str) -> int | None:
        """The inode a path names, or None."""
        ino = L["ROOT_INO"]
        for name in split_path(path):
            if self.inode(ino).type != L["T_DIR"]:
                return None
            ino = next((e.ino for e in self.entries(ino) if e.name == name), None)
            if ino is None:
                return None
        return ino

    def parent_of(self, path: str) -> tuple[int, str]:
        """The directory a new path would go in, and its last name."""
        names = split_path(path)
        if not names:
            raise FsError("the root has no name")
        check_name(names[-1])
        if len("/" + "/".join(names)) > L["PATH_MAX"]:
            raise FsError(f"a path has at most {L['PATH_MAX']} characters: {path}")
        parent = self.lookup("/".join(names[:-1]))
        if parent is None or self.inode(parent).type != L["T_DIR"]:
            raise FsError(f"no such directory: /{'/'.join(names[:-1])}")
        return parent, names[-1]

    def is_dir(self, path: str) -> bool:
        ino = self.lookup(path)
        return ino is not None and self.inode(ino).type == L["T_DIR"]

    def listdir(self, path: str = "/") -> list[tuple[str, Inode]]:
        """Each entry of a directory but . and .., with its inode."""
        ino = self.lookup(path)
        if ino is None:
            raise FsError(f"no such directory: {path}")
        return [
            (e.name, self.inode(e.ino))
            for e in self.entries(ino)
            if e.name not in (".", "..")
        ]

    def mkdir(self, path: str) -> int:
        parent, name = self.parent_of(path)
        if self.lookup(path) is not None:
            raise FsError(f"{path} is already there")
        node = self.new_inode(L["T_DIR"])
        node.links = 2
        self.put_inode(node)
        self.add_entry(node.number, ".", node.number)
        self.add_entry(node.number, "..", parent)
        self.add_entry(parent, name, node.number)
        up = self.inode(parent)
        up.links += 1
        self.put_inode(up)
        return node.number

    def read_trytes(self, path: str) -> list[int]:
        ino = self.lookup(path)
        if ino is None:
            raise FsError(f"no such file: {path}")
        node = self.inode(ino)
        if node.type != L["T_FILE"]:
            raise FsError(f"{path} is a directory")
        return self.contents(node)

    def read(self, path: str) -> str:
        trytes = self.read_trytes(path)
        if is_program(trytes):
            raise FsError(f"{path} is a program, not text")
        return "".join(chr(c) for c in trytes)

    def write(self, path: str, text: str) -> None:
        """Make a text file, or replace one at the same path."""
        check_text(text, path)
        self.write_trytes(path, [ord(c) for c in text])

    def write_trytes(self, path: str, trytes: list[int]) -> None:
        """Make a file of any trytes, or replace one at the same path."""
        parent, name = self.parent_of(path)
        ino = self.lookup(path)
        if ino is None:
            if room_for(len(trytes)) > len(self.free_blocks()):
                raise FsError(f"{path}: no room")
            node = self.new_inode(L["T_FILE"])
            try:
                self.add_entry(parent, name, node.number)
            except FsError:
                node.type = L["T_FREE"]
                self.put_inode(node)
                raise
            node.links = 1
        else:
            node = self.inode(ino)
            if node.type != L["T_FILE"]:
                raise FsError(f"{path} is a directory")
        try:
            self.set_contents(node, trytes)
        except FsError:
            if ino is None:  # undo the new name
                self.drop_entry(parent, name)
                node.type = L["T_FREE"]
                self.put_inode(node)
            raise

    def remove(self, path: str) -> None:
        """Remove a file, or a directory with nothing in it."""
        parent, name = self.parent_of(path)
        ino = self.lookup(path)
        if ino is None:
            raise FsError(f"no such file: {path}")
        node = self.inode(ino)
        if node.type == L["T_DIR"]:
            if self.listdir(path):
                raise FsError(f"{path} is not empty")
            up = self.inode(parent)
            up.links -= 1
            self.put_inode(up)
            node.links = 0
        else:
            node.links -= 1
        self.drop_entry(parent, name)
        if node.links == 0:
            self.release(node)
            node.type = L["T_FREE"]
        self.put_inode(node)

    # --- checking an image

    def check(self) -> None:
        """Walk the tree from the root: every inode in use is reached, with
        as many links as names; every block in use belongs to one inode,
        and the map says so."""
        for block in (0, L["FS_INODE_BLOCK"]):
            if not self.used(block):
                raise FsError(f"block {block} is marked free")
        if self.inode(L["ROOT_INO"]).type != L["T_DIR"]:
            raise FsError("the root is not a directory")
        owner = {0: "the header", L["FS_INODE_BLOCK"]: "the inodes"}
        links = self._walk(owner)
        for number in range(1, L["FS_INODES"]):
            node = self.inode(number)
            if node.type == L["T_FREE"]:
                continue
            if number not in links:
                raise FsError(f"inode {number} is in use but has no name")
            if node.links != links[number]:
                raise FsError(
                    f"inode {number} has {node.links} links, not {links[number]}"
                )
        for block in range(self.count):
            if self.used(block) != (block in owner):
                state = "used" if self.used(block) else "free"
                raise FsError(f"block {block} is marked {state}")

    def _walk(self, owner: dict[int, str]) -> dict[int, int]:
        """Every inode the tree reaches, with the links it should have;
        each one's blocks go in owner."""
        root = L["ROOT_INO"]
        links: dict[int, int] = {}
        todo = [(root, root)]
        while todo:
            ino, parent = todo.pop()
            if ino in links:
                raise FsError(f"directory inode {ino} is reached twice")
            links[ino] = 2
            self._check_blocks(self.inode(ino), owner)
            for e in self._dir_entries(ino, parent):
                child = self.inode(e.ino)
                if child.type == L["T_DIR"]:
                    links[ino] += 1
                    todo.append((e.ino, ino))
                elif child.type != L["T_FILE"]:
                    raise FsError(f"{e.name} names free inode {e.ino}")
                elif e.ino in links:
                    links[e.ino] += 1
                else:
                    links[e.ino] = 1
                    self._check_blocks(child, owner)
        return links

    def _dir_entries(self, ino: int, parent: int) -> list[Entry]:
        """A directory's entries but . and .., once those are checked."""
        entries = self.entries(ino)
        by_name = {e.name: e.ino for e in entries}
        if len(by_name) != len(entries):
            raise FsError(f"directory inode {ino} repeats a name")
        if by_name.get(".") != ino or by_name.get("..") != parent:
            raise FsError(f"directory inode {ino} has wrong . or ..")
        others = [e for e in entries if e.name not in (".", "..")]
        for e in others:
            if not L["ROOT_INO"] < e.ino < L["FS_INODES"]:
                raise FsError(f"{e.name}: no inode {e.ino}")
        return others

    def _check_blocks(self, node: Inode, owner: dict[int, str]) -> None:
        what = f"inode {node.number}"
        if node.size < 0 or blocks_for(node.size) > L["NDIRECT"] + PAGE // 3:
            raise FsError(f"{what}: size {node.size}")
        if node.type == L["T_DIR"] and node.size % L["DIRENT"]:
            raise FsError(f"{what}: a directory's size is whole entries")
        n = blocks_for(node.size)
        extra = [b for b in node.direct[n:] if b != L["NO_BLOCK"]]
        if n <= L["NDIRECT"] and node.indirect != L["NO_BLOCK"]:
            extra.append(node.indirect)
        if extra:
            raise FsError(f"{what}: blocks past its size")
        if node.indirect != L["NO_BLOCK"]:
            self._own(node.indirect, what, owner)
        for block in self.block_list(node):
            if block != L["NO_BLOCK"]:
                self._own(block, what, owner)

    def _own(self, block: int, what: str, owner: dict[int, str]) -> None:
        if not 0 < block < self.count:
            raise FsError(f"{what}: no block {block}")
        if block in owner:
            raise FsError(f"{what}: block {block} is also {owner[block]}'s")
        owner[block] = what


# --- the command line --------------------------------------------------------------


_IMPORT = re.compile(r'^\s*import\s+"([^"]+\.tc)"\s*;', re.MULTILINE)


def libraries(source: Path) -> list[Path]:
    """The Trice files a .tc file imports, and theirs, in the order they
    are first imported: what its program is linked with."""
    found: list[Path] = []
    pending = [source]
    while pending:
        file = pending.pop(0)
        for name in _IMPORT.findall(file.read_text()):
            library = (file.parent / name).resolve()
            if library != source.resolve() and library not in found:
                found.append(library)
                pending.append(library)
    return found


ROOT = Path(__file__).resolve().parent.parent
RUST_TARGET = "riscv32imac-unknown-none-elf"
_CARGO_TOML = """\
[package]
name = "{name}"
version = "0.1.0"
edition = "2024"

[lib]
path = "{source}"
crate-type = ["staticlib"]

[profile.release]
opt-level = "s"
panic = "abort"
codegen-units = 1
"""


def rust_ir(source: Path) -> list[Path]:
    """The LLVM IR rustc writes for a Rust program and for core, built
    from source with it (detrytus docs/rust.md): the program's module
    first. Builds share a target directory, so core is built once."""
    cargo = shutil.which("cargo")
    if cargo is None:
        raise FsError("no cargo to build Rust with")
    work = Path(tempfile.gettempdir()) / f"trylobite-rust-{os.getuid()}"
    name = re.sub(r"\W", "_", source.stem).lower()
    project = work / name
    project.mkdir(parents=True, exist_ok=True)
    (project / "Cargo.toml").write_text(
        _CARGO_TOML.format(name=name, source=source.resolve())
    )
    target = work / "target"
    # Where cargo leaves the IR moved in 1.100 (deps/ before, build/<crate>/
    # <hash>/out/ since), so look under the whole release directory.
    release = target / RUST_TARGET / "release"
    env = {
        **os.environ,
        "RUSTC_BOOTSTRAP": "1",
        "RUSTFLAGS": "--emit=llvm-ir,link -Zunstable-options -Cpanic=immediate-abort",
        "CARGO_TARGET_DIR": str(target),
    }
    target_args = ["--release", "--target", RUST_TARGET]
    # Cleaned first, so its IR is written afresh: a build cargo thinks is
    # up to date writes none.
    clean = ["clean", "--quiet", "-p", name]
    build = ["build", "--quiet", "-Zbuild-std=core"]
    for command in (clean, build):
        done = subprocess.run(
            [cargo, *command, *target_args],
            cwd=project,
            env=env,
            capture_output=True,
            text=True,
        )
        if done.returncode != 0:
            raise FsError(done.stderr.strip())

    def newest(pattern: str) -> list[Path]:
        return sorted(release.rglob(pattern), key=lambda p: p.stat().st_mtime)

    program = newest(f"{name}-*.ll")
    core = newest("core-*.ll")
    if not program or not core:
        found = ", ".join(sorted(p.name for p in release.rglob("*.ll"))) or "none"
        raise FsError(f"cargo left no LLVM IR for {source} (in {release}: {found})")
    return [program[-1], core[-1]]


def assemble(source: Path) -> bytes:
    """The image detrytus makes of a program's source: `detrytus asm` for
    assembly, `detrytus ll` of rustc's IR for Rust (.rs), and for Trice
    (.tc) `detrytus link` of the program with the Trice files it imports,
    each compiled on its own (detrytus docs/linker.md), so the program
    carries only the library functions it calls."""
    binary = os.environ.get("DETRYTUS") or shutil.which("detrytus")
    if binary is None:
        raise FsError("no detrytus command to assemble with: set DETRYTUS")
    with tempfile.TemporaryDirectory() as work:
        out = Path(work) / "program.dti"
        if source.suffix == ".tc":
            # The program first: it imports lib/start.s, which places it.
            command = ["link", str(source), *map(str, libraries(source))]
        elif source.suffix == ".rs":
            includes = [LAYOUT, ROOT / "lib" / "rust" / "start.s"]
            command = ["ll", *map(str, rust_ir(source))]
            for include in includes:
                command += ["--include", str(include)]
        else:
            command = ["asm", str(source)]
        done = subprocess.run(
            [binary, *command, "-o", str(out)],
            capture_output=True,
            text=True,
        )
        if done.returncode != 0:
            raise FsError(done.stderr.strip())
        return out.read_bytes()


def put(fs: Filesystem, file: Path, path: str | None = None) -> str:
    """Add a host file: an assembled image, or a .s, .tc or .rs file built
    here, as a program, anything else as text. A program is named after its
    file without .dti, .s, .tc or .rs and goes in /bin, made if missing; text keeps its
    file's name and goes in /. A path puts it there instead, or in that
    directory if one is there. Returns where it went."""
    data = assemble(file) if file.suffix in (".s", ".tc", ".rs") else file.read_bytes()
    program = data[:4] == DTI_MAGIC
    name = file.stem if program else file.name
    if path is None:
        if program and fs.lookup("bin") is None:
            fs.mkdir("bin")
        path = f"/bin/{name}" if program else f"/{name}"
    elif fs.is_dir(path):
        path = f"{path.rstrip('/')}/{name}"
    if program:
        fs.write_trytes(path, program_file(data))
    else:
        fs.write(path, data.decode())
    return path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("new", help="make a new filesystem, with files")
    p.add_argument("image", type=Path)
    p.add_argument("blocks", type=int)
    p.add_argument("files", type=Path, nargs="*")
    p = sub.add_parser("ls", help="list a directory")
    p.add_argument("image", type=Path)
    p.add_argument("path", nargs="?", default="/")
    p = sub.add_parser("cat", help="print a file")
    p.add_argument("image", type=Path)
    p.add_argument("path")
    p = sub.add_parser("put", help="add or replace a file")
    p.add_argument("image", type=Path)
    p.add_argument("file", type=Path)
    p.add_argument("path", nargs="?")
    p = sub.add_parser("mkdir", help="make a directory")
    p.add_argument("image", type=Path)
    p.add_argument("path")
    p = sub.add_parser("rm", help="remove a file or an empty directory")
    p.add_argument("image", type=Path)
    p.add_argument("path")
    args = parser.parse_args(argv)

    try:
        if args.command == "new":
            fs = Filesystem.new(args.blocks)
            for file in args.files:
                put(fs, file)
            fs.save(args.image)
        elif args.command == "ls":
            for name, node in Filesystem.load(args.image).listdir(args.path):
                if node.type == L["T_DIR"]:
                    print(f"{'':8} {name}/")
                else:
                    print(f"{node.size:8} {name}")
        elif args.command == "cat":
            sys.stdout.write(Filesystem.load(args.image).read(args.path))
        else:
            fs = Filesystem.load(args.image)
            if args.command == "put":
                put(fs, args.file, args.path)
            elif args.command == "mkdir":
                fs.mkdir(args.path)
            else:
                fs.remove(args.path)
            fs.save(args.image)
    except (FsError, OSError) as e:
        print(f"fs: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
