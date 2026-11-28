"""Job control (kernel/rust/trykern/src/jobs.rs and signal.rs): stop
signals stop a process and SIGCONT sets it going, waitpid with
WAIT_UNTRACED reports a stop, process groups and killpg, children that
start held, a stopped orphan sent SIGHUP; the console server's Ctrl-Z
and SIGTTIN; and the shell's jobs, fg, bg and kill."""

import re

import pytest

from tests.kernel import GETC, ROOT, assemble_file, bin_disk, run_image, wait_for
from tests.kernel import run as run_kernel
from tests.test_files import L, report, said
from tests.test_signals import EXIT_A1, FOREVER, SPAWN, action, kill

CTRL_Z = "\x1a"
CTRL_C = "\x03"


def waitpid(pid: str = "s1", options: str = "WAIT_UNTRACED") -> str:
    return (
        f"li a0, SYS_WAITPID\n        mv a1, {pid}\n        li a2, {options}\n"
        "        sys"
    )


def both(step: str) -> str:
    """Step, printing the a0 and then the a1 it leaves."""
    return step + "\n        mv s2, a1\n        call putn\n        mv a0, s2"


def state(pid: str = "s1") -> str:
    """a0 = the PI_STATE proc reports for process pid (data=PINFO)."""
    return (
        f"li a0, SYS_PROC\n        mv a1, {pid}\n        la a2, pinfo\n        sys\n"
        "        lw a0, pinfo + PI_STATE"
    )


PINFO = """
        .align 1
pinfo:  .words PROCINFO / 3
"""


def setpgrp(pid: str, pgrp: str, held: int = 0) -> str:
    return (
        f"li a0, SYS_SETPGRP\n        li a1, {pid}\n        li a2, {pgrp}\n"
        f"        li a3, {held}\n        sys"
    )


def setpgrp_r(pid: str, pgrp: str) -> str:
    """setpgrp with both from registers."""
    return (
        f"li a0, SYS_SETPGRP\n        mv a1, {pid}\n        mv a2, {pgrp}\n        sys"
    )


def getpgrp(pid: str) -> str:
    return f"li a0, SYS_GETPGRP\n        mv a1, {pid}\n        sys"


def killpg(group: str, sig: str) -> str:
    return (
        f"li a0, SYS_KILLPG\n        mv a1, {group}\n        li a2, FOR_SELF\n"
        f"        li a3, {sig}\n        sys"
    )


def spawn_to(reg: str, program: int = 1) -> str:
    return (
        f"li a0, SYS_SPAWN\n        li a1, {program}\n        sys\n        mv {reg}, a0"
    )


def test_sigstop_stops_a_process_until_sigcont():
    program = report(
        SPAWN,
        kill("SIGSTOP"),
        both(waitpid()),
        state(),
        kill("SIGCONT"),
        state(),
        kill("SIGKILL"),
        both(wait_for("s1")),
        data=PINFO,
    )
    result = run_kernel(program, FOREVER)
    got = said(result)
    assert got[6] in (L["ST_READY"], L["ST_RUNNING"]), result.console
    got[6] = L["ST_READY"]  # waiting for a hart, or on another
    assert got == [
        1,
        L["KILL_STOPPED"],
        L["WAIT_STOPPED"],
        L["SIGSTOP"],
        L["ST_STOPPED"],
        L["KILL_CAUGHT"],
        L["ST_READY"],
        0,
        L["WAIT_KILLED"],
        L["SIGKILL"],
    ], result.console


def test_a_stop_is_reported_once_and_plain_wait_waits_for_the_end():
    # The child stops itself, then is set going and exits with 7: the
    # first waitpid sees the stop, the second, after SIGCONT, the end.
    child = f"""
        li    a0, SYS_GETPID
        sys
        mv    a1, a0
        li    a0, SYS_KILL
        li    a2, KILL_ANY
        li    a3, SIGTSTP
        sys
        li    a1, 7
        {EXIT_A1}"""
    program = report(
        SPAWN,
        waitpid(),
        kill("SIGCONT"),
        both(waitpid()),
    )
    assert said(run_kernel(program, child)) == [
        1,
        L["WAIT_STOPPED"],
        L["KILL_CAUGHT"],
        L["WAIT_EXITED"],
        7,
    ]


def test_sigstop_cannot_be_caught_ignored_or_blocked_but_sigtstp_can():
    program = report(
        action("SIGSTOP", "SIG_IGN"),
        action("SIGSTOP", "SIG_CATCH"),
        action("SIGTSTP", "SIG_IGN"),
        SPAWN,
        kill("SIGTSTP"),  # the child keeps init's ignoring: it goes on
        kill("SIGSTOP"),  # but this stops it all the same
        kill("SIGCONT"),
        kill("SIGKILL"),
    )
    result = run_kernel(program, FOREVER)
    assert said(result) == [
        L["E_INVAL"],
        L["E_INVAL"],
        L["SIG_DFL"],
        1,
        L["KILL_CAUGHT"],
        L["KILL_STOPPED"],
        L["KILL_CAUGHT"],
        0,
    ], result.console


def test_waitpid_takes_only_wait_untraced():
    result = run_kernel(report(SPAWN, waitpid("s1", "2")), FOREVER)
    assert said(result)[1] == L["E_INVAL"]


def test_process_groups_join_the_parents_unless_it_chose_and_killpg_signals_one():
    program = report(
        "li s0, FOR_SELF\n" + getpgrp("s0"),  # init leads group 0
        spawn_to("s1"),
        getpgrp("s1"),  # the child is in init's group
        "li s0, PGRP_NEW\n" + setpgrp_r("s1", "s0"),
        getpgrp("s1"),  # now in one of its own: 1
        setpgrp("PGRP_CHILDREN", "PGRP_NEW"),
        spawn_to("s3"),
        getpgrp("s3"),  # leads its own: 2
        "li a0, SYS_SETPGRP\n        li a1, PGRP_CHILDREN\n        mv a2, s1\n"
        "        li a3, 0\n        sys",
        spawn_to("s4"),
        getpgrp("s4"),  # joins group 1
        "li s0, 9\n" + setpgrp_r("s3", "s0"),  # nobody's group: not allowed
        killpg("s1", "SIGKILL"),  # 1 and 3 end, 2 goes on
        wait_for("s1"),
        wait_for("s4"),
        kill("SIGTERM", "s3"),
    )
    result = run_kernel(program, FOREVER)
    assert said(result) == [0, 1, 0, 0, 1, 0, 2, 2, 0, 3, 1, L["E_PERM"], 0, 2, 2, 0], (
        result.console
    )


def test_held_children_start_stopped_and_a_stop_meanwhile_outlasts_the_release():
    child = f"li a1, 7\n        {EXIT_A1}"
    program = report(
        setpgrp("PGRP_CHILDREN", "PGRP_NEW", held=1),
        SPAWN,
        state(),  # held: stopped, though nobody was told
        "li s0, PGRP_RELEASE\n" + setpgrp_r("s0", "s1"),
        both(wait_for("s1")),
        spawn_to("s1"),
        kill("SIGTSTP"),  # as a Ctrl-Z before the release
        "li s0, PGRP_RELEASE\n" + setpgrp_r("s0", "s1"),
        both(waitpid()),
        kill("SIGCONT"),
        both(wait_for("s1")),
        data=PINFO,
    )
    result = run_kernel(program, child)
    assert said(result) == [
        0,
        1,
        L["ST_STOPPED"],
        0,
        L["WAIT_EXITED"],
        7,
        2,
        L["KILL_STOPPED"],
        0,
        L["WAIT_STOPPED"],
        L["SIGTSTP"],
        L["KILL_CAUGHT"],
        L["WAIT_EXITED"],
        7,
    ], result.console


def test_a_stopped_process_whose_parent_ends_gets_sighup():
    # Program 1 starts program 2, which spins, stops it and exits: with
    # nobody to set it going, program 2 is sent SIGHUP, which ends it,
    # and the machine powers off.
    parent = f"""
        {spawn_to("s1", 2)}
        {kill("SIGSTOP")}
        li    a1, 0
        {EXIT_A1}"""
    init = f"""
        {SPAWN}
        {wait_for("s1")}
        li    a1, 0
        {EXIT_A1}"""
    result = run_kernel(init, parent, FOREVER)
    assert "process 2 killed" in result.console
    assert result.exit_code == 0, result.console


def reader_child() -> str:
    """Program 1: read the console until a code point comes, then exit
    with it (a read cut short by a stop is made again)."""
    return f"""
1:      {GETC}
        li    t0, E_INTR
        beq   a0, t0, 1b
        mv    a1, a0
        {EXIT_A1}"""


def test_ctrl_z_stops_the_foreground_group_and_the_read_goes_on_after():
    # Init starts the reader held, in a group of its own, gives the group
    # the console and releases it: the Ctrl-Z typed ahead stops it and
    # throws away the "ab" before it; after SIGCONT it reads the "c".
    init = report(
        setpgrp("PGRP_CHILDREN", "PGRP_NEW", held=1),
        SPAWN,
        "CALL_CONSOLE\n        li a2, CN_FOREGROUND\n        mv a3, s1\n        sys",
        "li s0, PGRP_RELEASE\n" + setpgrp_r("s0", "s1"),
        both(waitpid()),
        kill("SIGCONT"),
        both(wait_for("s1")),
    )
    result = run_kernel(init, reader_child(), input="ab" + CTRL_Z + "c", console=True)
    assert said(result)[4:] == [
        L["WAIT_STOPPED"],
        L["SIGTSTP"],
        L["KILL_CAUGHT"],
        L["WAIT_EXITED"],
        ord("c"),
    ], result.console


def test_a_background_read_of_the_console_stops_the_reader_with_sigttin():
    # Init names itself the foreground; the reader, in a group of its own,
    # is stopped when it reads, and reads once given the console.
    init = report(
        "li s0, 0\n        CALL_CONSOLE\n        li a2, CN_FOREGROUND\n"
        "        mv a3, s0\n        sys",
        setpgrp("PGRP_CHILDREN", "PGRP_NEW"),
        SPAWN,
        both(waitpid()),
        "CALL_CONSOLE\n        li a2, CN_FOREGROUND\n        mv a3, s1\n        sys",
        kill("SIGCONT"),
        both(wait_for("s1")),
    )
    result = run_kernel(init, reader_child(), input="x", console=True)
    assert said(result)[3:] == [
        L["WAIT_STOPPED"],
        L["SIGTTIN"],
        0,
        L["KILL_CAUGHT"],
        L["WAIT_EXITED"],
        ord("x"),
    ], result.console


# --- the shell -------------------------------------------------------------


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said_to(shell, typed: str) -> str:
    result = run_image(shell, input=typed, disk=bin_disk(), max_steps=60_000_000)
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_ctrl_z_stops_a_job_and_fg_sets_it_going_in_the_foreground(shell):
    out = said_to(shell, "upper\n" + CTRL_Z + "echo $?\njobs\nps\nfg %up\nxy\n")
    assert "[1]+ stopped  upper\n" in out
    assert "\n148\n" in out
    assert "[1]+ stopped  upper\n$ ps" in out
    assert re.search(r"\d+ +\d+ stopped .* upper\n", out), out
    assert "fg %up\nupper\nXY\n" in out


def test_bg_sets_a_job_going_and_it_stops_again_when_it_reads(shell):
    out = said_to(shell, "upper\n" + CTRL_Z + "bg\nwait %1\necho $?\nkill %1\njobs\n")
    assert "[1] upper &\n" in out
    assert re.search(r"\n14[89]\n", out), out  # stopped again (SIGTTIN)
    assert "[1] exit 143  upper\n" in out  # SIGTERM ended it


def test_a_background_job_that_reads_is_stopped(shell):
    out = said_to(shell, "upper &\nwait\nwait %1\necho $?\njobs\nkill -9 %%\n")
    assert "[1] stopped  upper\n" in out
    # 149 (SIGTTIN) if wait saw it stop, 148 (SIGTSTP, which the shell
    # takes it was) if the process table told the prompt first
    assert re.search(r"\n14[89]\n", out), out
    assert "[1]+ stopped  upper\n" in out


def test_ctrl_c_ends_every_program_of_a_pipeline(shell):
    typed = "upper | wc\n" + CTRL_C + "echo after\n"
    result = run_image(shell, input=typed, disk=bin_disk(), max_steps=60_000_000)
    assert result.exit_code == 0, result.console
    killed = re.findall(r"process \d+ killed", result.after_boot)
    assert len(killed) >= 2, result.console
    assert "after\n" in result.after_boot


def test_exit_warns_of_stopped_jobs_once(shell):
    out = said_to(shell, "upper\n" + CTRL_Z + "exit 0\nexit 0\necho not here\n")
    assert "sh: there are stopped jobs\n" in out
    assert "not here" not in out


def test_job_specs_name_jobs(shell):
    out = said_to(
        shell,
        "upper\n" + CTRL_Z + "wc &\nwait\njobs\nkill %-\nfg %9\nbg %nothing\n"
        "kill -9 %%\njobs\n",
    )
    assert "[2] stopped  wc\n" in out  # it read the console
    assert "[1]- stopped  upper\n[2]+ stopped  wc\n" in out
    assert "[1] exit 143  upper\n" in out
    assert "sh: fg: no such job: %9\n" in out
    assert "sh: bg: no such job: %nothing\n" in out
