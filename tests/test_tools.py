"""The system tools of bin/: dmesg, uname, uptime, free, ps, kill, sleep,
top and df, run from the shell on a disk of bin/."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str, on=None, max_steps: int = 12_000_000):
    result = run_image(shell, input=typed, disk=on or bin_disk(), max_steps=max_steps)
    assert result.exit_code == 0, result.console
    return result


def said(shell, typed: str, on=None, **options) -> str:
    """What the shell and its programs printed after the boot, without
    the kernel's lines."""
    console = session(shell, typed, on, **options).after_boot
    return re.sub(r"trylobite: [^\n]*\n", "", console)


def test_dmesg_says_the_boot_report_again(shell):
    result = session(shell, "dmesg\n")
    out = re.sub(r"trylobite: process \d+ exited[^\n]*\n", "", result.after_boot)
    _, _, again = out.partition("$ dmesg\n")
    boot = result.console.partition("$ ")[0]
    assert again.startswith(boot)  # every line of the boot, init's too


def test_uname_names_the_system_and_its_version(shell):
    assert said(shell, "uname\nuname -a\nuname -x\n") == (
        "$ uname\ntrylobite\n"
        "$ uname -a\ntrylobite 0.1.0 detrytus\n"
        "$ uname -x\nusage: uname [-a]\nsh: exit 2\n$ \n"
    )


def test_uptime_says_ticks_processes_and_harts(shell):
    from tests import kernel

    out = said(shell, "uptime\n")
    harts = "1 hart" if kernel.HARTS == 1 else f"{kernel.HARTS} harts"
    assert re.fullmatch(
        rf"\$ uptime\nup \d+ ticks, 9 processes, {harts}\n\$ \n", out
    ), out


def test_free_adds_up(shell):
    out = said(shell, "free\n")
    lines = out.splitlines()
    assert lines[1].split() == ["total", "used", "free"]
    pages = [int(n) for n in lines[2].split()[1:]]
    trytes = [int(n) for n in lines[3].split()[1:]]
    assert pages[0] == 243 and pages[1] + pages[2] == pages[0]
    assert trytes == [n * 19683 for n in pages]


def test_ps_lists_every_process_by_name(shell):
    out = said(shell, "ps\n/bin/ps\n")
    rows = [line.split() for line in out.splitlines() if line[:1] == " "]
    assert rows[0] == ["PID", "PPID", "STATE", "PAGES", "TIME", "NAME"]
    table = {int(r[0]): (r[1], r[2], r[5]) for r in rows[1:10]}
    assert table == {
        0: ("-", "receive", "init"),
        1: ("0", "receive", "consd"),
        2: ("0", "receive", "diskd"),
        3: ("0", "receive", "fsd"),
        4: ("0", "receive", "piped"),
        5: ("0", "receive", "netd"),
        6: ("0", "receive", "ipd"),
        7: ("0", "wait", "sh"),
        8: ("7", "run", "ps"),
    }
    assert rows[-1][1:3] + rows[-1][5:] == ["7", "run", "ps"]  # not /bin/ps


def test_kill_ends_a_server_and_init_starts_it_again(shell):
    result = session(shell, "kill 0\nkill 99\nkill x\nkill 4\nps\n")
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert out.startswith(
        "$ kill 0\nkill: 0: not allowed\nsh: exit 1\n"
        "$ kill 99\nkill: 99: no such process\nsh: exit 1\n"
        "$ kill x\nusage: kill [-SIGNAL] PID... | kill -l\nsh: exit 2\n"
        "$ kill 4\n"
    ), out
    assert "process 4 killed" in result.console
    assert "init: pipe ended, starting it again" in result.console
    assert re.search(r" 0 receive +4 +\d+ piped\n", out), out


def test_sleep_waits_its_ticks(shell):
    out = said(shell, "uptime\nsleep 3000000\nuptime\nsleep\n")
    ups = [int(n) for n in re.findall(r"up (\d+) ticks", out)]
    assert ups[1] - ups[0] >= 3_000_000
    assert out.endswith("$ sleep\nusage: sleep TICKS\nsh: exit 2\n$ \n")


def test_top_shows_a_screen_each_period(shell):
    from tests import kernel

    out = said(shell, "top -n 2\ntop -n 0\n", max_steps=40_000_000)
    screens = out.split("\x1b[H\x1b[2J")
    assert len(screens) == 3
    for screen in screens[1:]:
        lines = screen.splitlines()
        assert re.fullmatch(
            r"top - \d\d:\d\d:\d\d up \d+:\d\d:\d\d, trylobite 0\.1\.0, "
            r"load average: \d+\.\d\d, \d+\.\d\d, \d+\.\d\d",
            lines[0],
        ), lines[0]
        assert re.fullmatch(
            r"Tasks: +9 total, +1 running, +0 ready, +8 waiting, +0 zombie", lines[1]
        ), lines[1]
        cpus = lines[2 : 2 + kernel.HARTS]
        for cpu in cpus:
            m = re.fullmatch(
                r"%Cpu-?\d *: +([\d.]+) us, +([\d.]+) sy, +([\d.]+) id", cpu
            )
            assert m, cpu
            assert 99.0 <= sum(float(x) for x in m.groups()) <= 100.0, cpu
        mem = lines[2 + kernel.HARTS]
        m = re.fullmatch(
            r"Mem   : +243 pages total, +(\d+) free, +(\d+) used  "
            r"\(19,683 trytes a page\)",
            mem,
        )
        assert m and int(m[1]) + int(m[2]) == 243, mem
        table = lines[4 + kernel.HARTS :]
        header = "PID PPID STATE PAGES CPU% TIME NAME"
        assert table[0].split() == header.split()
        assert re.fullmatch(r" +8 +7 run +\d+ +\d+\.\d +\d+ top", table[9]), table[9]
    assert out.endswith("$ top -n 0\nusage: top [-n COUNT]\nsh: exit 2\n$ \n")


def test_df_counts_blocks_and_inodes(shell):
    on = bin_disk()
    blocks = on[1]
    out = said(shell, "df\nwrite notes hello\ndf\n", on)
    rows = [line.split() for line in out.splitlines() if line.startswith("disk0")]
    before, after = ([int(n.rstrip("%")) for n in row[1:7]] for row in rows)
    assert before[0] == after[0] == blocks
    assert before[1] + before[2] == blocks
    assert after[1] == before[1] + 1  # the new file's block
    assert after[5] == before[5] - 1  # and its inode
    assert before[4] == 728
