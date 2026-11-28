"""Run every test on a machine with one hart and on one with three, with
the Rust parts of the kernel and file server built afresh first; and when
a test finds a disk damaged, keep it, and how to replay the run that
wrote it, in test-failures/ (or $TRYLOBITE_FAILURES)."""

import os
import re
import shlex
import shutil
from datetime import UTC, datetime
from pathlib import Path

import pytest

from tests import kernel
from tools import kernel as kernel_rust
from tools import server as server_rust
from tools.fs import FsError

FAILURES = Path(os.environ.get("TRYLOBITE_FAILURES") or kernel.ROOT / "test-failures")


@pytest.fixture(autouse=True, scope="session")
def kernel_built():
    """kernel/trykern.s, which include/kernel.s includes (tools/kernel.py),
    and user/fsd-rust.s, which user/fsd.s does (tools/server.py)."""
    try:
        kernel_rust.build()
        server_rust.build()
    except kernel_rust.BuildError as e:
        pytest.exit(
            f"cannot build the kernel's or file server's Rust: {e}", returncode=1
        )


@pytest.fixture(autouse=True, params=[1, 3], ids=["1hart", "3harts"])
def harts(request, monkeypatch):
    monkeypatch.setattr(kernel, "HARTS", request.param)
    return request.param


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    error = call.excinfo.value if call.excinfo else None
    if report.failed and isinstance(error, FsError) and error.disk is not None:
        kept = keep_damaged(item.nodeid, error)
        if kept:
            report.sections.append(("damaged disk", f"kept in {kept}"))


def keep_damaged(nodeid: str, error: FsError) -> Path | None:
    """Copy the damaged disk to FAILURES/<test>/disk.img, with what the
    emulator said (stderr.txt), the image it ran and the input it was
    typed, the disk as the run found it (when the test's last run was
    the one that wrote it), and how to run the machine again
    (replay.txt): the directory, or None without the disk's run."""
    run = kernel.RUNS.get(str(error.disk))
    if run is None or not error.disk.exists():
        return None
    where = FAILURES / re.sub(r"[^\w.-]+", "_", nodeid)
    where.mkdir(parents=True, exist_ok=True)
    shutil.copy(error.disk, where / "disk.img")
    (where / "stderr.txt").write_text(run.stderr)
    args = list(run.args)
    image = Path(args[-1])
    if image.suffix == ".dti" and image.exists():
        shutil.copy(image, where / "image.dti")
        args[-1] = "image.dti"
    if "--input" in args:
        typed = Path(args[args.index("--input") + 1])
        if typed.exists():
            shutil.copy(typed, where / "input.txt")
            args[args.index("--input") + 1] = "input.txt"
    disk = args.index("--disk") + 1
    if run.before is not None:
        (where / "before.img").write_bytes(run.before)
        args[disk] = "copy-of-before.img"
    if "--clock" not in args:
        # The machine read the host's clock: a replay can start its clock
        # at the same second, though not tick for tick.
        args[-1:-1] = ["--clock", str(int(run.started))]
    started = datetime.fromtimestamp(run.started, UTC)
    (where / "replay.txt").write_text(
        f"{error}\n"
        f"The run started at {started:%Y-%m-%d %H:%M:%S.%f} UTC.\n"
        "To run it again here, on a copy of before.img (the run writes to it):\n"
        "  cp before.img copy-of-before.img\n"
        f"  detrytus {shlex.join(args)}\n"
    )
    return where
