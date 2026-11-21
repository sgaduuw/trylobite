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


def exit_with(register: str) -> str:
    return f"mv a1, {register}\n        {EXIT}"


def build(
    init: str, prog1: str = DONE, prog2: str = DONE, ram_pages: int = RAM_PAGES
) -> Image:
    """The kernel with init as program 0 and prog1, prog2 to spawn."""
    source = f"""
        .equ  RAM_PAGES, {ram_pages}
        .equ  NPROG, 3
        .include "include/kernel.s"
        .section prog0, P_PROG0 * PAGE, V_USER
{init}
        .section prog1, P_PROG1 * PAGE, V_USER
{prog1}
        .section prog2, P_PROG2 * PAGE, V_USER
{prog2}
"""
    # On stdin, .include paths start from the working directory: the root.
    return _assemble(["-"], stdin=source)


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

    def words(self, addresses: list[int]) -> list[int | None]:
        """Words of physical memory once the program has stopped, each
        centred on an address; None where nothing is mapped. The debugger
        runs the image to the same end and reads them with xp."""
        script = _WORK / f"read{next(_names)}.txt"
        script.write_text("continue\n" + "".join(f"xp {a} 1\n" for a in addresses))
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


def run_image(
    image: Image,
    ram_pages: int = RAM_PAGES,
    max_steps: int = 2_000_000,
    harts: int | None = None,
    plug: list[tuple[int, int]] = (),
    unplug: list[tuple[int, int]] = (),
    input: str | None = None,
) -> Run:
    """Run an image; input, if given, is what the console has to read."""
    harts = HARTS if harts is None else harts
    hotplug = hotplug_options(plug, unplug)
    inputs = input_options(input)
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
    return Run(done.stdout, code, image, ram_pages, harts, steps, hotplug, inputs)


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
) -> Run:
    image = build(init, prog1, prog2, ram_pages)
    return run_image(image, ram_pages, max_steps, harts, plug, unplug, input)
