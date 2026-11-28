#!/usr/bin/env python3
"""Build and read trylobite filesystem images (docs/filesystem.md).

    tools/fs.py new IMAGE BLOCKS [FILE ...] [--boot KERNEL]
                                              a new filesystem, with files,
                                              and a kernel to boot
    tools/fs.py boot IMAGE KERNEL             put in a kernel to boot, or
                                              replace it
    tools/fs.py ls IMAGE [PATH]               a directory's files and sizes
    tools/fs.py cat IMAGE PATH                a file's text, to stdout
    tools/fs.py put IMAGE FILE [PATH]         add a file, or replace it
    tools/fs.py mkdir IMAGE PATH              make a directory
    tools/fs.py rm IMAGE PATH                 remove a file or empty directory
    tools/fs.py check IMAGE                   check it all (fsck)

A file is text, each code point one tryte between 1 and 9,841, or a
program: `put` given an image assembled by `detrytus asm` (a .dti file)
stores it as a program file in /bin, where the shell finds it, and
given a .s file assembles it first, or a Trice .tc file builds it
first, linked with the .tc files it imports, or a Rust .rs file builds
it with cargo and `detrytus ll` (docs/rust.md) (with $DETRYTUS, or
detrytus on the PATH). Paths start at the
root, with or without a leading slash.

A kernel to boot is a build such as shell.s, assembled here, or its
.dti image: its RAM pages, from page 1 to its last, go in consecutive
blocks, and block 0's boot record names them, so that detrytus' boot
ROM loads them and starts the firmware at FW_BOOT (`detrytus run --disk
IMAGE` with no program). The image is a detrytus disk
file, two bytes per tryte, so `detrytus run --disk IMAGE` attaches it.
The filesystem is lib/rust/tryfs's, which tools/rust/tryfs, a host
tool built here with cargo (or $TRYFS), reads and writes.
The format's numbers are read from
include/layout.s, which the kernel and programs share.
"""

from __future__ import annotations

import argparse
import ast
import contextlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

try:
    from tools import toolchain
except ImportError:  # run as a script: tools/ is on the path, not the repository
    import toolchain  # type: ignore[no-redef]

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


def boot_image(data: bytes) -> list[Block]:
    """An assembled kernel's RAM pages, from page 1 to its last, as the
    blocks that hold them: what the boot ROM loads into pages 1 and up.
    Page 0 is the boot ROM's, so the image's own boot page stays out."""
    pages: dict[int, Block] = {}
    for start, trytes in read_dti(data):
        for address, tryte in enumerate(trytes, start):
            page = (address + HALF) // PAGE
            if page < 0:
                raise FsError(f"a kernel to boot fills device page {page}")
            if page > 0:
                block = pages.setdefault(page, Block.blank())
                block.trytes[address - page * PAGE + HALF] = tryte
    if not pages:
        raise FsError("a kernel to boot has nothing in RAM pages")
    return [pages.get(p, Block.blank()) for p in range(1, max(pages) + 1)]


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
#
# The format is lib/rust/tryfs's, the code the file server runs; its host
# tool, tools/rust/tryfs, does the work here, so the two cannot disagree.

TRYFS_CRATE = Path(__file__).resolve().parent / "rust" / "tryfs"
_tryfs: list[str] = []


def tryfs_binary() -> str:
    """The host tool: $TRYFS, or built with cargo (once a run; cargo
    rebuilds it only when its crate or tryfs changed)."""
    if not _tryfs:
        given = os.environ.get("TRYFS")
        if given:
            _tryfs.append(given)
        else:
            cargo = shutil.which("cargo")
            if cargo is None:
                raise FsError("no cargo to build tools/rust/tryfs with (or set TRYFS)")
            done = subprocess.run(
                [cargo, "build", "--release", "--quiet"],
                cwd=TRYFS_CRATE,
                capture_output=True,
                text=True,
            )
            if done.returncode:
                raise FsError(f"building tools/rust/tryfs: {done.stderr.strip()}")
            _tryfs.append(str(TRYFS_CRATE / "target" / "release" / "tryfs"))
    return _tryfs[0]


@dataclass
class Time:
    secs: int
    nanos: int


@dataclass
class Inode:
    """What stat says of a file or directory."""

    number: int
    type: int
    mode: int
    uid: int
    gid: int
    links: int
    size: int
    blocks: int  # data blocks it holds
    parent: int  # a directory's parent
    atime: Time
    mtime: Time
    ctime: Time
    btime: Time
    data: list[int]  # each file block's disk block, NO_BLOCK for a hole

    @classmethod
    def of(cls, j: dict) -> Inode:
        return cls(
            j["ino"],
            j["type"],
            j["mode"],
            j["uid"],
            j["gid"],
            j["links"],
            j["size"],
            j["blocks"],
            j["parent"],
            *(Time(*j[t]) for t in ("atime", "mtime", "ctime", "btime")),
            j.get("data", []),
        )

    @property
    def is_dir(self) -> bool:
        return self.type == L["T_DIR"]


def check_text(text: str, what: str) -> None:
    for c in text:
        if not 1 <= ord(c) <= HALF:
            raise FsError(f"{what}: code point {ord(c)} does not fit in a tryte")


def split_path(path: str) -> list[str]:
    """A path's names. It starts at the root whether or not it starts with
    a slash, since nothing has a current directory yet."""
    return [name for name in path.split("/") if name]


def _path(path: str) -> str:
    return "/" + "/".join(split_path(path))


def _trytes_bytes(trytes: list[int]) -> bytes:
    return struct.pack(f"<{len(trytes)}h", *trytes)


class Filesystem:
    """A filesystem image, held in a file of its own: change it, then save
    it. Each change is one transaction of the host tool."""

    def __init__(self, data: bytes):
        self._dir = tempfile.TemporaryDirectory(prefix="tryfs-")
        self.image = Path(self._dir.name) / "disk.img"
        self.image.write_bytes(data)

    def _run(self, *args: str, stdin: bytes | None = None) -> str:
        done = subprocess.run(
            [tryfs_binary(), args[0], str(self.image), *args[1:]],
            input=stdin,
            capture_output=True,
        )
        if done.returncode:
            message = done.stderr.decode(errors="replace").strip()
            raise FsError(message.removeprefix("tryfs: "))
        return done.stdout.decode()

    def _file(self, name: str, trytes: list[int]) -> str:
        file = Path(self._dir.name) / name
        file.write_bytes(_trytes_bytes(trytes))
        return str(file)

    @classmethod
    def new(cls, count: int, disk_blocks: int | None = None) -> Filesystem:
        """A new filesystem of count blocks, on a disk of disk_blocks."""
        made = cls(b"")
        done = subprocess.run(
            [
                tryfs_binary(),
                "new",
                str(made.image),
                str(count),
                str(disk_blocks or count),
            ],
            capture_output=True,
            text=True,
        )
        if done.returncode:
            raise FsError(done.stderr.strip().removeprefix("tryfs: "))
        return made

    @classmethod
    def load(cls, path: Path) -> Filesystem:
        """A disk's filesystem, checked first."""
        made = cls(Path(path).read_bytes())
        made.check()
        return made

    def save(self, path: Path) -> None:
        Path(path).write_bytes(self.image.read_bytes())

    def raw(self) -> list[Block]:
        """The disk's blocks, as they are."""
        return read_blocks(self.image)

    def set_raw(self, blocks: list[Block]) -> None:
        """Replace the disk's blocks (to damage it, in a test)."""
        write_blocks(self.image, blocks)

    def check(self) -> None:
        """Check it all (fsck): FsError says what is wrong."""
        self._run("check")

    def info(self) -> dict:
        """The superblock, and the free blocks."""
        return json.loads(self._run("info"))

    @property
    def count(self) -> int:
        return self.info()["blocks"]

    def free_blocks(self) -> list[int]:
        return self.info()["free"]

    # --- the kernel to boot

    def boot_blocks(self) -> range:
        """The blocks block 0's boot record names, if it has one."""
        boot = self.info()["boot"]
        return range(boot[0], boot[0] + boot[1]) if boot else range(0)

    def set_boot(self, image: list[Block]) -> None:
        """Put a kernel's pages (boot_image) in the first run of free
        blocks that holds them, freeing the one there was, and point the
        boot record at them."""
        trytes = [t for block in image for t in block.trytes]
        self._run("boot", self._file("boot", trytes), "1", str(L["FW_BOOT"]))

    # --- what is there

    def stat(self, path: str) -> Inode:
        return Inode.of(json.loads(self._run("stat", _path(path))))

    def inode(self, number: int) -> Inode:
        return Inode.of(json.loads(self._run("istat", str(number))))

    def lookup(self, path: str) -> int | None:
        """The inode a path names, or None."""
        try:
            return self.stat(path).number
        except FsError as e:
            if f"({L['E_NOENT']})" in str(e) or f"({L['E_NOTDIR']})" in str(e):
                return None
            raise

    def is_dir(self, path: str) -> bool:
        try:
            return self.stat(path).is_dir
        except FsError:
            return False

    def listdir(self, path: str = "/") -> list[tuple[str, Inode]]:
        """Each entry of a directory but . and .., in order, with its inode."""
        out = self._run("ls", _path(path))
        found = []
        for line in out.splitlines():
            j = json.loads(line)
            found.append((j["name"], Inode.of(j)))
        return found

    def read_trytes(self, path: str) -> list[int]:
        done = subprocess.run(
            [tryfs_binary(), "get", str(self.image), _path(path), "-"],
            capture_output=True,
        )
        if done.returncode:
            raise FsError(done.stderr.decode().strip().removeprefix("tryfs: "))
        data = done.stdout
        return list(struct.unpack(f"<{len(data) // 2}h", data))

    def read(self, path: str) -> str:
        trytes = self.read_trytes(path)
        if is_program(trytes):
            raise FsError(f"{path} is a program, not text")
        return "".join(chr(c) for c in trytes)

    # --- changes

    def mkdir(self, path: str) -> int:
        self._run("mkdir", _path(path))
        return self.stat(path).number

    def write(self, path: str, text: str) -> None:
        """Make a text file, or replace one at the same path."""
        check_text(text, path)
        self.write_trytes(path, [ord(c) for c in text])

    def write_trytes(self, path: str, trytes: list[int]) -> None:
        """Make a file of any trytes, or replace one at the same path."""
        self._run("put", _path(path), self._file("put", trytes))

    def remove(self, path: str) -> None:
        """Remove a file, or a directory with nothing in it."""
        self._run("rmdir" if self.is_dir(path) else "rm", _path(path))

    def rename(self, old: str, new: str) -> None:
        self._run("mv", _path(old), _path(new))

    def chmod(self, path: str, mode: int) -> None:
        self._run("chmod", _path(path), str(mode))

    def chown(self, path: str, uid: int, gid: int) -> None:
        self._run("chown", _path(path), str(uid), str(gid))

    def utimes(self, path: str, atime: int, mtime: int) -> None:
        self._run("utimes", _path(path), str(atime), str(mtime))


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
TRYSTD = ROOT / "lib" / "rust" / "trystd"  # the system library, a crate
_CARGO_TOML = """\
[package]
name = "{name}"
version = "0.1.0"
edition = "2024"

[lib]
path = "{source}"
crate-type = ["staticlib"]

[dependencies]
trystd = {{ path = "{trystd}" }}

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
        _CARGO_TOML.format(name=name, source=source.resolve(), trystd=TRYSTD)
    )
    # The pinned toolchain: rustup reads the copy here (tools/toolchain.py).
    (project / "rust-toolchain.toml").write_text(toolchain.TOOLCHAIN_FILE.read_text())
    env, target = toolchain.cargo_env(project, work / "target")
    # Where cargo leaves the IR moved in 1.100 (deps/ before, build/<crate>/
    # <hash>/out/ since), so look under the whole release directory.
    release = target / RUST_TARGET / "release"
    target_args = ["--release", "--target", RUST_TARGET]
    # Cleaned first, so its IR is written afresh: a build cargo thinks is
    # up to date writes none.
    clean = ["clean", "--quiet", "-p", name]
    build = ["build", "--quiet", "-Zbuild-std=core,alloc"]
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
    alloc = newest("alloc-*.ll")
    trystd = newest("trystd-*.ll")
    return [program[-1], core[-1], *alloc[-1:], *trystd[-1:]]


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


def kernel(file: Path) -> bytes:
    """A kernel to boot, as an image: a .dti file, or a build such as
    shell.s assembled."""
    return assemble(file) if file.suffix == ".s" else file.read_bytes()


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


def change(args: argparse.Namespace) -> None:
    """put, boot, mkdir or rm: load the image, change it, save it."""
    fs = Filesystem.load(args.image)
    if args.command == "put":
        put(fs, args.file, args.path)
    elif args.command == "boot":
        fs.set_boot(boot_image(kernel(args.kernel)))
    elif args.command == "mkdir":
        fs.mkdir(args.path)
    else:
        fs.remove(args.path)
    fs.save(args.image)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("new", help="make a new filesystem, with files")
    p.add_argument("image", type=Path)
    p.add_argument("blocks", type=int)
    p.add_argument("files", type=Path, nargs="*")
    p.add_argument("--boot", type=Path, metavar="KERNEL", help="a kernel to boot")
    p = sub.add_parser("boot", help="put in a kernel to boot")
    p.add_argument("image", type=Path)
    p.add_argument("kernel", type=Path)
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
    p = sub.add_parser("check", help="check the filesystem (fsck)")
    p.add_argument("image", type=Path)
    args = parser.parse_args(argv)

    try:
        if args.command == "new":
            fs = Filesystem.new(args.blocks)
            if args.boot:
                fs.set_boot(boot_image(kernel(args.boot)))
            for file in args.files:
                put(fs, file)
            fs.save(args.image)
        elif args.command == "ls":
            for name, node in Filesystem.load(args.image).listdir(args.path):
                if node.is_dir:
                    print(f"{'':8} {name}/")
                else:
                    print(f"{node.size:8} {name}")
        elif args.command == "check":
            Filesystem.load(args.image)
        elif args.command == "cat":
            sys.stdout.write(Filesystem.load(args.image).read(args.path))
        else:
            change(args)
    except (FsError, OSError) as e:
        print(f"fs: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
