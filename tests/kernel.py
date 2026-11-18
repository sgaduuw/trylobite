"""Build the kernel with chosen user programs and run it."""

import re
from dataclasses import dataclass
from pathlib import Path

from detrytus.asm import Image, assemble
from detrytus.machine import Machine, StepLimit

ROOT = Path(__file__).parent.parent
RAM_PAGES = 20


def build(prog0: str, prog1: str) -> Image:
    """The kernel with prog0 and prog1 as processes 0 and 1."""
    source = f"""
        .include "kernel.s"
        .section user0, P_USER0 * PAGE
{prog0}
        .section user1, P_USER1 * PAGE
{prog1}
"""
    # The file name only sets where .include starts looking: the repo root.
    return assemble(source, str(ROOT / "test-build.s"))


@dataclass
class Run:
    console: str
    exit_code: int | None  # None if it was still running at the step limit
    machine: Machine

    def exits(self) -> dict[int, int]:
        """Process number to exit code, from the kernel's messages."""
        found = re.findall(r"process (\d+) exited with code (-?\d+)", self.console)
        return {int(p): int(c) for p, c in found}

    def ticks(self) -> int:
        m = re.search(r"after (\d+) timer interrupts", self.console)
        assert m, self.console
        return int(m.group(1))


def run_image(image: Image, max_steps: int = 300_000) -> Run:
    m = Machine(ram_pages=RAM_PAGES, seed=1)
    m.load(image)
    try:
        code: int | None = m.run(max_steps).exit_code
    except StepLimit:
        code = None
    return Run(m.console.text, code, m)


def run(prog0: str, prog1: str, max_steps: int = 300_000) -> Run:
    return run_image(build(prog0, prog1), max_steps)


EXIT = "li a0, SYS_EXIT\n        sys"


def exit_with(register: str) -> str:
    return f"mv a1, {register}\n        {EXIT}"
