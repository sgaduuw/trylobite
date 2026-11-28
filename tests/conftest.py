"""Run every test on a machine with one hart and on one with three, with
the Rust parts of the kernel and file server built afresh first."""

import pytest

from tests import kernel
from tools import kernel as kernel_rust
from tools import server as server_rust


@pytest.fixture(autouse=True, scope="session")
def kernel_built():
    """kernel/trykern.s, which include/kernel.s includes (tools/kernel.py),
    and user/fsd-rust.s, which user/fsd.s does (tools/server.py)."""
    try:
        kernel_rust.build()
        server_rust.build()
    except kernel_rust.BuildError as e:
        pytest.exit(f"cannot build the kernel's or file server's Rust: {e}", returncode=1)


@pytest.fixture(autouse=True, params=[1, 3], ids=["1hart", "3harts"])
def harts(request, monkeypatch):
    monkeypatch.setattr(kernel, "HARTS", request.param)
    return request.param
