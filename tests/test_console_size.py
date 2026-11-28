"""The console's size: the console server answers IO_WINSIZE with the
rows and columns the machine's console registers say (detrytus run
--console-size here; a live console follows the terminal). stty size
says them, vi fills them and the shell's Tab list fits their width."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, size=None, max_steps=8_000_000) -> str:
    result = run_image(
        shell, input=typed, disk=bin_disk(), console_size=size, max_steps=max_steps
    )
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_stty_size_says_rows_and_columns(shell):
    assert said(shell, "stty size\n", (30, 100)) == "$ stty size\n30 100\n$ \n"


def test_stty_size_fails_without_a_size_or_a_console(shell):
    unknown = "stty: the console's size is not known\nsh: exit 1\n"
    assert said(shell, "stty size\n") == f"$ stty size\n{unknown}$ \n"
    out = said(shell, "stty size < /bin/vi\nstty\n", (30, 100))
    # A file's server does not know IO_WINSIZE: not the console.
    assert out == (
        f"$ stty size < /bin/vi\n{unknown}$ stty\nusage: stty size\nsh: exit 2\n$ \n"
    )


def test_vi_fills_the_console(shell):
    def tildes(size):
        out = said(shell, "vi f\n:q\n", size, max_steps=80_000_000)
        first = out.split('"f" [New]')[0]
        return first.count("~\x1b[K")

    # Every row but the status line, the first holding the empty line.
    assert tildes((6, 30)) == 4
    assert tildes(None) == 22  # 24 by 80 when the size is not known


def test_vi_cuts_lines_at_the_console_width(shell):
    disk = bin_disk(f="x" * 50 + "\n")
    result = run_image(
        shell, input="vi f\n:q\n", disk=disk, console_size=(6, 30), max_steps=80_000_000
    )
    assert "x" * 30 + "\n" in result.console.replace("\r", "")
    assert "x" * 31 not in result.console


def test_the_tab_list_fits_the_console_width(shell):
    # Columns of 5 + 2 + 1 = 8: two fit in 20.
    out = said(shell, "u\t\t\n", (24, 20))
    assert out.startswith("$ u\x07\nunset   uname\nupper   uptime\n$ u\n")
