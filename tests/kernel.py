"""Build the kernel with chosen programs and run it on the detrytus
command, the `detrytus` binary (tools/install-detrytus installs it).

Programs are assembled with `detrytus asm`, run with `detrytus run`, and
memory after a run is read with `detrytus debug` and its `xp` command.
DETRYTUS names the binary; without it, `detrytus` on the PATH is used.
"""

import itertools
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).parent.parent
RAM_PAGES = 40
# Harts the machine has when a test does not say: the suite runs once
# with each of these (tests/conftest.py sets it).
HARTS = 1
STEP_LIMIT = 124  # detrytus run's exit status when the program never powered off

# From docs/isa.md in the detrytus repository: trap causes (8.5) and the
# numbers of the argument registers (3.1).
LOAD_PAGE_FAULT = 7
BREAKPOINT = 5
REGISTERS = {"a0": 1, "a1": 2, "a2": 3}

_WORK = Path(tempfile.mkdtemp(prefix="trylobite-"))
_names = itertools.count()


def detrytus(*args: str, stdin: str | None = None) -> subprocess.CompletedProcess[str]:
    binary = os.environ.get("DETRYTUS") or shutil.which("detrytus")
    if binary is None:
        raise RuntimeError(
            "no detrytus command: run tools/install-detrytus, or set DETRYTUS"
        )
    return subprocess.run(
        [binary, *args], input=stdin, capture_output=True, text=True, cwd=ROOT
    )


@dataclass
class Image:
    """An assembled image: where it is, and what its metadata names."""

    path: Path
    symbols: dict[str, int]
    labels: dict[str, int]
    trytes: set[int]  # the addresses it fills


def read_image(path: Path) -> Image:
    """Read a .dti file's metadata and the addresses its segments fill."""
    data = path.read_bytes()
    assert data[:4] == b"DTI\x01", path
    (meta_len,) = struct.unpack_from("<I", data, 4)
    meta = json.loads(data[8 : 8 + meta_len])
    pos = 8 + meta_len
    (count,) = struct.unpack_from("<I", data, pos)
    pos += 4
    trytes: set[int] = set()
    for _ in range(count):
        start, n = struct.unpack_from("<qI", data, pos)
        pos += 12 + -(-9 * n // 5)  # five trits to a byte
        trytes.update(range(start, start + n))
    return Image(path, meta["symbols"], meta["labels"], trytes)


def _assemble(args: list[str], stdin: str | None = None) -> Image:
    out = _WORK / f"build{next(_names)}.dti"
    done = detrytus("asm", *args, "-o", str(out), stdin=stdin)
    assert done.returncode == 0, done.stderr
    return read_image(out)


def assemble_file(path: Path) -> Image:
    return _assemble([str(path)])


EXIT = "li a0, SYS_EXIT\n        sys"
DONE = f"li a1, 0\n        {EXIT}"

# An init that starts programs 1 and 2 and leaves: they get process
# numbers 1 and 2, and init's slot, 0, is free again.
SPAWN_BOTH = f"""
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        li    a0, SYS_SPAWN
        li    a1, 2
        sys
        {DONE}
"""


def send_to_2(value: int) -> str:
    """Send value to process 2, waiting for it to exist: init may be
    preempted between its two spawns, so process 1 can run first."""
    return f"""
1:      li    a0, SYS_SEND
        li    a1, 2
        li    a2, {value}
        sys
        li    t0, E_NOPROC
        bne   a0, t0, 2f
        li    a0, SYS_YIELD
        sys
        j     1b
2:"""


def wait_for(register: str) -> str:
    """Wait for the child whose number is in register; a0 and a1 then say
    how it ended."""
    return f"li a0, SYS_WAIT\n        mv a1, {register}\n        sys"


# getc from the console server, in a build with console: a0 = the next
# code point, or GETC_NONE.
GETC = "CALL_CONSOLE\n        li    a2, CN_GETC\n        sys"


def exit_with(register: str) -> str:
    return f"mv a1, {register}\n        {EXIT}"


# The servers a build can add, from program 3 on: the disk server, the
# file server, which needs it, the console server and the pipe server.
# init's first lines start them in that order, so with files the disk
# server is process 1 and the file server process 2.
SERVERS = {
    "disk": "user/diskd.s",
    "fs": "user/fsd.s",
    "console": "user/consd.s",
    "pipe": "user/piped.s",
}


def start(program: int) -> str:
    return f"""
        li    a0, SYS_SPAWN
        li    a1, {program}
        sys
"""


# A line of its own, CALL_FS, CALL_DISK or CALL_CONSOLE, starts a call to that server
# in a test program: build expands it to a lookup of the server's name,
# waiting for it to register, then a0 = SYS_CALL and a1 = the server, so
# that a2 onwards follow as for any call. Each program gets its own copy
# of the name, since all programs share one symbol table.
CALLS = {
    name: re.compile(rf"^( *(?:\w+: *)?)CALL_{name.upper()}$", re.M)  # a label may lead
    for name in SERVERS
}


def find_servers(program: str, n: int) -> str:
    """program with each CALL_ line expanded, and the name strings,
    labelled find_fs_n, find_disk_n and find_console_n, added at its end."""
    pad = " " * 8
    for name, pattern in CALLS.items():
        if not pattern.search(program):
            continue
        label = f"find_{name}_{n}"
        program = pattern.sub(
            lambda m, label=label: (
                f"{m.group(1)}li    a0, SYS_LOOKUP\n{pad}la    a1, {label}\n"
                f"{pad}li    a2, LOOKUP_WAIT\n{pad}sys\n{pad}mv    a1, a0\n"
                f"{pad}li    a0, SYS_CALL"
            ),
            program,
        )
        program = f'{program}\n{label}: .string "{name}"\n'
    return program


def build(
    init: str,
    prog1: str = DONE,
    prog2: str = DONE,
    ram_pages: int = RAM_PAGES,
    files: bool = False,
    disk_server: bool = False,
    console: bool = False,
    pipes: bool = False,
) -> Image:
    """The kernel with init as program 0 and prog1, prog2 to spawn; with
    disk_server, also the disk server (user/diskd.s), with files the
    file server (user/fsd.s) after it, and with console the console server
    (user/consd.s), and with pipes the pipe server (user/piped.s), all of
    which init starts first."""
    init, prog1, prog2 = (
        find_servers(p, n) for n, p in enumerate((init, prog1, prog2))
    )
    servers = [
        *(["disk"] if files or disk_server else []),
        *(["fs"] if files else []),
        *(["console"] if console else []),
        *(["pipe"] if pipes else []),
    ]
    server = ""
    for k, name in enumerate(servers, 3):
        server += f"""
        .section prog{k}, (P_PROG0 + {k}) * PAGE, V_USER
        .include "{SERVERS[name]}"
"""
    init = "".join(start(k) for k in range(3, 3 + len(servers))) + init
    source = f"""
        .equ  RAM_PAGES, {ram_pages}
        .equ  NPROG, {3 + len(servers)}
        .include "include/kernel.s"
        .section prog0, P_PROG0 * PAGE, V_USER
{init}
        .section prog1, (P_PROG0 + 1) * PAGE, V_USER
{prog1}
        .section prog2, (P_PROG0 + 2) * PAGE, V_USER
{prog2}
{server}"""
    # On stdin, .include paths start from the working directory: the root.
    return _assemble(["-"], stdin=source)


# The kernel's boot report ends with this line, and init in shell.s ends
# its own (each server it started) with the second, just before the shell
# prints its first prompt.
BOOT_END = "trylobite: starting init\n"
SHELL_START = "init: starting sh\n"


def after_boot(console: str) -> str:
    """What a console printed after the boot report: after the kernel's
    lines up to starting init, and after init's up to starting the shell
    when it starts one."""
    _, found, rest = console.partition(BOOT_END)
    assert found, console
    _, found, shell = rest.partition(SHELL_START)
    return shell if found else rest


@dataclass
class Run:
    console: str
    exit_code: int | None  # None if it was still running at the step limit
    image: Image
    ram_pages: int
    harts: int
    steps: int | None  # None if it was still running at the step limit
    hotplug: list[str]  # the --plug and --unplug options it ran with
    input_options: list[str]  # --input FILE, if it was given console input
    disk_options: list[str]  # --disk FILE --disk-blocks N, if it had a disk

    def words(self, addresses: list[int]) -> list[int | None]:
        """Words of physical memory once the program has stopped, each
        centred on an address; None where nothing is mapped. The debugger
        runs the image to the same end and reads them with xp. It closes
        the console first, as run does, so getc ends at the end of the
        input rather than waiting for more."""
        # Running again would write the disk again: not the same run.
        assert not self.disk_options, "words() cannot rerun a run with a disk"
        script = _WORK / f"read{next(_names)}.txt"
        script.write_text("eof\ncontinue\n" + "".join(f"xp {a} 1\n" for a in addresses))
        done = detrytus(
            "debug",
            str(self.image.path),
            "--ram-pages",
            str(self.ram_pages),
            "--harts",
            str(self.harts),
            *self.hotplug,
            *self.input_options,
            "-x",
            str(script),
            "--batch",
        )
        assert done.returncode == 0, done.stderr
        found = re.findall(
            r"^ *(-?\d+)  +(?:(-?\d+)  0t[-0+]{27}|<unmapped>)$", done.stdout, re.M
        )
        assert [int(a) for a, _ in found] == addresses, done.stdout[-500:]
        return [int(v) if v else None for _, v in found]

    @property
    def after_boot(self) -> str:
        return after_boot(self.console)

    def exits(self) -> list[tuple[int, int]]:
        """(process, exit code) from the kernel's messages, in order."""
        found = re.findall(r"process (\d+) exited with code (-?\d+)", self.console)
        return [(int(p), int(c)) for p, c in found]

    def code_of(self, pid: int) -> int:
        codes = [c for p, c in self.exits() if p == pid]
        assert len(codes) == 1, (pid, self.console)
        return codes[0]

    def ticks(self) -> int:
        m = re.search(r"after (\d+) timer interrupts", self.console)
        assert m, self.console
        return int(m.group(1))


def hotplug_options(plug: list[tuple[int, int]], unplug: list[tuple[int, int]]):
    """detrytus options adding harts, or asking them to go, at given
    times: each entry is (time, hart)."""
    options = []
    for flag, changes in (("--plug", plug), ("--unplug", unplug)):
        for time, hart in changes:
            options += [flag, f"{time}:{hart}"]
    return options


def input_options(text: str | None) -> list[str]:
    """--input with a file holding text, so that a debugger run reading
    memory afterwards gets the same input; none for None."""
    if text is None:
        return []
    path = _WORK / f"input{next(_names)}.txt"
    path.write_text(text)
    return ["--input", str(path)]


def debug_session(
    image: Image,
    script: str,
    harts: int | None = None,
    ram_pages: int | None = None,
    disk: tuple[Path, int] | None = None,
) -> str:
    """Run an image in the debugger under script's commands, and return
    what it printed: its replies and the program's output, in order.
    Unlike run, the console stays open until the script says eof, so
    `input` can type more while the program waits. The machine has the
    RAM the build is for unless ram_pages says otherwise."""
    harts = HARTS if harts is None else harts
    ram_pages = image.symbols["RAM_PAGES"] if ram_pages is None else ram_pages
    path = _WORK / f"session{next(_names)}.txt"
    path.write_text(script)
    done = detrytus(
        "debug",
        str(image.path),
        "--ram-pages",
        str(ram_pages),
        "--harts",
        str(harts),
        *disk_options(disk),
        "-x",
        str(path),
        "--batch",
    )
    assert done.returncode == 0, done.stderr
    return done.stdout


def disk_options(disk: tuple[Path, int] | None) -> list[str]:
    """--disk FILE --disk-blocks N for a disk (file, blocks); none for None.
    The file is created if missing, and keeps what a run wrote."""
    if disk is None:
        return []
    path, blocks = disk
    return ["--disk", str(path), "--disk-blocks", str(blocks)]


def new_disk() -> Path:
    """A path for a disk file that does not exist yet."""
    return _WORK / f"disk{next(_names)}.img"


_BIN: dict[str, list[int]] = {}


def bin_disk(blocks: int = 32, **texts: str) -> tuple[Path, int]:
    """A new disk holding a filesystem with every program of bin/ in /bin,
    as the shell expects, and these text files in /: (path, blocks)."""
    from tools.fs import Filesystem, assemble, program_file

    if not _BIN:
        bin_ = ROOT / "bin"
        for source in sorted([*bin_.glob("*.s"), *bin_.glob("*.tc")]):
            # Trice (.tc) and assembly alike, in name order, as ls lists them.
            _BIN[source.stem] = program_file(assemble(source))
    made = Filesystem.new(blocks)
    made.mkdir("bin")
    for name, trytes in _BIN.items():
        made.write_trytes(f"bin/{name}", trytes)
    for name, text in texts.items():
        made.write(name, text)
    path = new_disk()
    made.save(path)
    return path, blocks


def run_image(
    image: Image,
    ram_pages: int | None = None,
    max_steps: int = 2_000_000,
    harts: int | None = None,
    plug: list[tuple[int, int]] = (),
    unplug: list[tuple[int, int]] = (),
    input: str | None = None,
    disk: tuple[Path, int] | None = None,
) -> Run:
    """Run an image; input, if given, is what the console has to read, and
    disk, if given, is (file, blocks) for its block device. The machine
    has the RAM the build is for unless ram_pages says otherwise."""
    harts = HARTS if harts is None else harts
    ram_pages = image.symbols["RAM_PAGES"] if ram_pages is None else ram_pages
    hotplug = hotplug_options(plug, unplug)
    inputs = input_options(input)
    disks = disk_options(disk)
    done = detrytus(
        "run",
        "--stats",
        "--ram-pages",
        str(ram_pages),
        "--max-steps",
        str(max_steps),
        "--harts",
        str(harts),
        *hotplug,
        *inputs,
        *disks,
        str(image.path),
    )
    code: int | None = None
    steps: int | None = None
    if done.returncode != STEP_LIMIT:
        # The full exit code is in the stats line; the status is only its
        # low byte.
        m = re.search(r"detrytus: (\d+) steps, exit (-?\d+)", done.stderr)
        assert m, done.stderr
        steps, code = int(m.group(1)), int(m.group(2))
    return Run(
        done.stdout, code, image, ram_pages, harts, steps, hotplug, inputs, disks
    )


def run(
    init: str,
    prog1: str = DONE,
    prog2: str = DONE,
    ram_pages: int = RAM_PAGES,
    max_steps: int = 2_000_000,
    harts: int | None = None,
    plug: list[tuple[int, int]] = (),
    unplug: list[tuple[int, int]] = (),
    input: str | None = None,
    disk: tuple[Path, int] | None = None,
    files: bool = False,
    disk_server: bool = False,
    console: bool = False,
    pipes: bool = False,
) -> Run:
    image = build(init, prog1, prog2, ram_pages, files, disk_server, console, pipes)
    return run_image(image, ram_pages, max_steps, harts, plug, unplug, input, disk)
