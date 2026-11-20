"""Run every test on a machine with one hart and on one with three."""

import pytest

from tests import kernel


@pytest.fixture(autouse=True, params=[1, 3], ids=["1hart", "3harts"])
def harts(request, monkeypatch):
    monkeypatch.setattr(kernel, "HARTS", request.param)
    return request.param
