#!/usr/bin/env python3
"""Build and read trylobite filesystem images (docs/filesystem.md).

    tools/fs.py new IMAGE BLOCKS [FILE ...]   a new filesystem, with files
    tools/fs.py ls IMAGE                      each file's size and name
    tools/fs.py cat IMAGE NAME                a file's text, to stdout
    tools/fs.py put IMAGE FILE [NAME]         add a file, or replace it
    tools/fs.py rm IMAGE NAME                 remove a file

A file is text, each code point one tryte between 1 and 9,841, or a
program: `put` given an image assembled by `detrytus asm` (a .dti file)
stores it as a program file, which the shell can run. The image is a
detrytus disk file, two bytes per tryte, so
`detrytus run --disk IMAGE` attaches it. The format's numbers are read
from include/layout.s, which the kernel and programs share.
"""

from __future__ import annotations

import argparse
import ast
import contextlib
import re
import struct
import sys
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
    """A program file's trytes, from an assembled image: EXEC_MAGIC, then
    the image, from V_USER - 1 to its last tryte, with any gap between its
    segments zero. It must be assembled to load where it runs, and fit
    between V_USER - 1 and the top of the page."""
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
    return split_word(L["EXEC_MAGIC"]) + image


def is_program(trytes: list[int]) -> bool:
    return len(trytes) >= 3 and join_word(trytes[:3]) == L["EXEC_MAGIC"]


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
class Entry:
    slot: int
    name: str
    size: int
    first: int


def entry_at(slot: int) -> int:
    return L["FS_DIR"] + slot * L["FS_DIRENT"]


def check_name(name: str) -> None:
    if not 1 <= len(name) <= L["FS_NAME_MAX"]:
        raise FsError(f"a name is 1 to {L['FS_NAME_MAX']} characters: {name!r}")
    if any(ord(c) <= ord(" ") or ord(c) > HALF for c in name):
        raise FsError(f"a name has no spaces or control characters: {name!r}")


def check_text(text: str, what: str) -> None:
    for c in text:
        if not 1 <= ord(c) <= HALF:
            raise FsError(f"{what}: code point {ord(c)} does not fit in a tryte")


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
        if not 2 <= self.count <= min(len(blocks), L["FS_MAX_BLOCKS"]):
            raise FsError(f"the header claims {self.count} blocks")
        self.head = head
        for entry in self.entries():
            self.chain(entry)  # every chain must be sound

    @classmethod
    def new(cls, count: int) -> Filesystem:
        if not 2 <= count <= L["FS_MAX_BLOCKS"]:
            raise FsError(f"a filesystem has 2 to {L['FS_MAX_BLOCKS']} blocks")
        blocks = [Block.blank() for _ in range(count)]
        head = blocks[0]
        head.set_word(L["FS_HEAD_MAGIC"], L["FS_MAGIC"])
        head.set_word(L["FS_HEAD_VERSION"], L["FS_VERSION"])
        head.set_word(L["FS_HEAD_BLOCKS"], count)
        head.set_word(L["FS_FAT"], L["FAT_END"])  # block 0 is the header's
        return cls(blocks)

    @classmethod
    def load(cls, path: Path) -> Filesystem:
        return cls(read_blocks(path))

    def save(self, path: Path) -> None:
        write_blocks(path, self.blocks)

    # The FAT, one word per block.
    def fat(self, block: int) -> int:
        return self.head.word(L["FS_FAT"] + 3 * block)

    def set_fat(self, block: int, value: int) -> None:
        self.head.set_word(L["FS_FAT"] + 3 * block, value)

    def free_blocks(self) -> list[int]:
        return [b for b in range(1, self.count) if self.fat(b) == L["FAT_FREE"]]

    # The directory.
    def entries(self) -> list[Entry]:
        found = []
        for slot in range(L["FS_FILES"]):
            at = entry_at(slot)
            name = ""
            for i in range(L["FS_NAME_MAX"] + 1):
                c = self.head.tryte(at + L["DE_NAME"] + i)
                if c == 0:
                    break
                name += chr(c) if c > 0 else "?"
            if not name:
                continue
            size = self.head.word(at + L["DE_SIZE"])
            first = self.head.word(at + L["DE_FIRST"])
            found.append(Entry(slot, name, size, first))
        return found

    def find(self, name: str) -> Entry | None:
        return next((e for e in self.entries() if e.name == name), None)

    def chain(self, entry: Entry) -> list[int]:
        """The blocks of a file, in order, checked against its size."""
        blocks, block, seen = [], entry.first, set()
        while block != L["FAT_END"]:
            if not 1 <= block < self.count or block in seen:
                raise FsError(f"{entry.name}: broken chain at block {block}")
            seen.add(block)
            blocks.append(block)
            block = self.fat(block)
        if entry.size < 0 or -(-entry.size // PAGE) != len(blocks):
            raise FsError(f"{entry.name}: {entry.size} trytes in {len(blocks)} blocks")
        return blocks

    def read_trytes(self, name: str) -> list[int]:
        entry = self.find(name)
        if entry is None:
            raise FsError(f"no such file: {name}")
        trytes = []
        for i, block in enumerate(self.chain(entry)):
            n = min(PAGE, entry.size - i * PAGE)
            trytes += self.blocks[block].trytes[:n]
        return trytes

    def read(self, name: str) -> str:
        trytes = self.read_trytes(name)
        if is_program(trytes):
            raise FsError(f"{name} is a program, not text")
        return "".join(chr(c) for c in trytes)

    def remove(self, name: str) -> None:
        entry = self.find(name)
        if entry is None:
            raise FsError(f"no such file: {name}")
        for block in self.chain(entry):
            self.set_fat(block, L["FAT_FREE"])
        at = entry_at(entry.slot)
        for i in range(L["FS_DIRENT"]):
            self.head.set_tryte(at + L["DE_NAME"] + i, 0)

    def write(self, name: str, text: str) -> None:
        """Add a text file, or replace one of the same name."""
        check_text(text, name)
        self.write_trytes(name, [ord(c) for c in text])

    def write_trytes(self, name: str, trytes: list[int]) -> None:
        """Add a file of any trytes, or replace one of the same name."""
        check_name(name)
        old = self.find(name)
        reusable = len(self.chain(old)) if old else 0
        need = -(-len(trytes) // PAGE)
        if need > len(self.free_blocks()) + reusable:
            raise FsError(f"{name}: no room for {need} blocks")
        if old:
            self.remove(name)
        used = {e.slot for e in self.entries()}
        slot = next((s for s in range(L["FS_FILES"]) if s not in used), None)
        if slot is None:
            raise FsError(f"{name}: the directory is full")
        blocks = self.free_blocks()[:need]
        for this, after in zip(blocks, [*blocks[1:], L["FAT_END"]], strict=False):
            self.set_fat(this, after)
        for i, block in enumerate(blocks):
            chunk = trytes[i * PAGE : (i + 1) * PAGE]
            self.blocks[block].trytes = chunk + [0] * (PAGE - len(chunk))
        at = entry_at(slot)
        for i, c in enumerate(name):
            self.head.set_tryte(at + L["DE_NAME"] + i, ord(c))
        self.head.set_word(at + L["DE_SIZE"], len(trytes))
        self.head.set_word(at + L["DE_FIRST"], blocks[0] if blocks else L["FAT_END"])


# --- the command line --------------------------------------------------------------


def put(fs: Filesystem, file: Path, name: str | None = None) -> None:
    """Add a host file: an assembled image as a program, anything else as
    text. Unless named, a program is called after its file without .dti,
    and text after its file."""
    data = file.read_bytes()
    if data[:4] == DTI_MAGIC:
        fs.write_trytes(name or file.name.removesuffix(".dti"), program_file(data))
    else:
        fs.write(name or file.name, data.decode())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("new", help="make a new filesystem, with files")
    p.add_argument("image", type=Path)
    p.add_argument("blocks", type=int)
    p.add_argument("files", type=Path, nargs="*")
    p = sub.add_parser("ls", help="list the files")
    p.add_argument("image", type=Path)
    p = sub.add_parser("cat", help="print a file")
    p.add_argument("image", type=Path)
    p.add_argument("name")
    p = sub.add_parser("put", help="add or replace a file")
    p.add_argument("image", type=Path)
    p.add_argument("file", type=Path)
    p.add_argument("name", nargs="?")
    p = sub.add_parser("rm", help="remove a file")
    p.add_argument("image", type=Path)
    p.add_argument("name")
    args = parser.parse_args(argv)

    try:
        if args.command == "new":
            fs = Filesystem.new(args.blocks)
            for file in args.files:
                put(fs, file)
            fs.save(args.image)
        elif args.command == "ls":
            for entry in Filesystem.load(args.image).entries():
                print(f"{entry.size:8} {entry.name}")
        elif args.command == "cat":
            sys.stdout.write(Filesystem.load(args.image).read(args.name))
        elif args.command == "put":
            fs = Filesystem.load(args.image)
            put(fs, args.file, args.name)
            fs.save(args.image)
        elif args.command == "rm":
            fs = Filesystem.load(args.image)
            fs.remove(args.name)
            fs.save(args.image)
    except (FsError, OSError) as e:
        print(f"fs: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
