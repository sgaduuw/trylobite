"""When a test finds a disk damaged after a run, tests/conftest.py keeps
the disk, what the emulator said and how to run the machine again, so
that a failure seen once (on CI, say) can be looked at afterwards."""

import pytest

from tests import conftest
from tests.test_files import disk, open_, report, run, said, string
from tools import fs
from tools.fs import Filesystem, FsError

L = fs.L


def test_a_damaged_disk_is_kept_with_how_to_replay_its_run(tmp_path, monkeypatch):
    on = disk(f="x")
    fresh = on[0].read_bytes()
    program = report(open_("p"), data=string("p", "f"))
    assert said(run(program, disk=on)) == [0]
    made = Filesystem.load(on[0])
    blocks = made.raw()
    # A superblock whose sum does not match, as a torn write would leave.
    at = L["BLOCK_W0"] + 3 * L["SB_NEXT_INO"]
    blocks[0].set_word(at, blocks[0].word(at) + 1)
    made.set_raw(blocks)
    made.save(on[0])
    with pytest.raises(FsError) as caught:
        Filesystem.load(on[0])
    assert caught.value.disk == on[0]

    monkeypatch.setattr(conftest, "FAILURES", tmp_path)
    kept = conftest.keep_damaged("tests/x.py::test_y[1hart]", caught.value)
    assert kept == tmp_path / "tests_x.py_test_y_1hart_"
    assert (kept / "disk.img").read_bytes() == on[0].read_bytes()
    assert (kept / "stderr.txt").exists() and (kept / "image.dti").exists()
    assert (kept / "before.img").read_bytes() == fresh
    replay = (kept / "replay.txt").read_text()
    assert "The run started at " in replay
    assert "--disk copy-of-before.img" in replay and "--clock " in replay
    assert replay.rstrip().endswith("image.dti")
