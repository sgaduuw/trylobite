"""Signals (kernel/rust/trykern/src/signal.rs): kill sends one, each does
its default, nothing, or runs the process's handler and comes back with
sigreturn; a thread's mask holds signals off; a caught signal cuts a
blocking call short with E_INTR; Ctrl-C is SIGINT; and trystd's signal
module (tests/rsig.rs) from inside a Rust program."""

import re

import pytest

from tests.kernel import GETC, ROOT, assemble_file, bin_disk, run_image, wait_for
from tests.kernel import run as run_kernel
from tests.test_files import L, report, said

CTRL_C = "\x03"
RSIG = ROOT / "tests" / "rsig.rs"


def child(body: str) -> str:
    """Program 1: body, then its handler c_h, which counts each signal
    and keeps the last, and goes back with sigreturn."""
    return f"""
        .gp   USER_GP
{body}
c_h:    sw    a0, c_got
        lw    t0, c_hits
        addi  t0, t0, 1
        sw    t0, c_hits
        li    a0, SYS_SIGRETURN
        sys
        .align 1
c_got:  .word 0
c_hits: .word 0
"""


def catch(sig: str, handler: str = "c_h") -> str:
    return (
        f"li a0, SYS_SIGACTION\n        li a1, {sig}\n"
        f"        li a2, SIG_CATCH\n        la a3, {handler}\n        sys"
    )


def action(sig: str, how: str) -> str:
    return (
        f"li a0, SYS_SIGACTION\n        li a1, {sig}\n        li a2, {how}\n        sys"
    )


def kill(sig: str, pid: str = "s1", on_behalf: str = "FOR_SELF") -> str:
    return (
        f"li a0, SYS_KILL\n        mv a1, {pid}\n        li a2, {on_behalf}\n"
        f"        li a3, {sig}\n        sys"
    )


def sigmask(how: str, mask: str) -> str:
    return (
        f"li a0, SYS_SIGMASK\n        li a1, {how}\n        li a2, {mask}\n        sys"
    )


SPAWN = "li a0, SYS_SPAWN\n        li a1, 1\n        sys\n        mv s1, a0"
RECV = "li a0, SYS_RECV\n        sys"
# The child tells init it is ready, with a message to process 0.
READY = "li a0, SYS_SEND\n        li a1, 0\n        li a2, 1\n        sys"
WAIT = wait_for("s1") + "\n        mv s2, a1\n        call putn\n        mv a0, s2"
EXIT_A1 = "li a0, SYS_EXIT\n        sys"
FOREVER = "1:      j 1b"


def send(value: int) -> str:
    return f"li a0, SYS_SEND\n        mv a1, s1\n        li a2, {value}\n        sys"


def test_sigterm_ends_a_process_by_default_and_wait_names_it():
    result = run_kernel(report(SPAWN, kill("SIGTERM"), WAIT), FOREVER)
    assert said(result) == [1, 0, L["WAIT_KILLED"], L["SIGTERM"]]
    assert "process 1 killed" in result.console


def test_an_ignored_signal_does_nothing():
    prog = child(
        f"{action('SIGTERM', 'SIG_IGN')}\n        {READY}\n        {RECV}\n"
        f"        mv a1, a0\n        {EXIT_A1}"
    )
    result = run_kernel(report(SPAWN, RECV, kill("SIGTERM"), send(42), WAIT), prog)
    assert said(result) == [1, 1, L["KILL_CAUGHT"], 0, L["WAIT_EXITED"], 42]


# The child catches SIGUSR1, then waits in recv with 777 in s5. Its exit
# code: the signal its handler saw * 100 + how many times it ran, then
# + 10,000 * how far s5 moved and + 1,000 * how far recv's result is from
# E_INTR: 1001 when the handler ran once, the wait was cut short and the
# registers came back.
TALLY = """
        lw    t0, c_got
        li    t1, 100
        mul   t0, t0, t1
        lw    t1, c_hits
        add   t0, t0, t1
        li    t1, 777
        sub   t1, s5, t1
        li    t2, 10000
        mul   t1, t1, t2
        add   t0, t0, t1
        li    t1, E_INTR
        sub   t1, s2, t1
        li    t2, 1000
        mul   t1, t1, t2
        add   a1, t0, t1
        li    a0, SYS_EXIT
        sys
"""


def test_a_caught_signal_runs_the_handler_and_cuts_a_wait_short():
    prog = child(
        f"{catch('SIGUSR1')}\n        li s5, 777\n        {READY}\n        {RECV}\n"
        f"        mv s2, a0\n{TALLY}"
    )
    result = run_kernel(report(SPAWN, RECV, kill("SIGUSR1"), WAIT), prog)
    assert said(result) == [1, 1, L["KILL_CAUGHT"], L["WAIT_EXITED"], 1001]


def test_a_blocked_signal_waits_until_the_thread_unblocks_it():
    # Blocked, SIGUSR1 neither runs the handler nor cuts recv short: recv
    # gets init's 5. Unblocking takes it before sigmask returns.
    prog = child(
        f"""{catch("SIGUSR1")}
        {sigmask("SIG_BLOCK", "1024")}
        {READY}
        {RECV}
        mv    s2, a0                   # 5
        lw    s3, c_hits               # 0: not yet
        {sigmask("SIG_UNBLOCK", "1024")}
        mv    s4, a0                   # the mask it had: 1024
        lw    t0, c_hits               # 1 now
        li    t1, 10
        mul   t0, t0, t1
        add   t0, t0, s2
        li    t1, 100
        mul   t1, s3, t1
        add   t0, t0, t1
        li    t1, 1000
        mul   t1, s4, t1
        add   a1, t0, t1
        {EXIT_A1}"""
    )
    result = run_kernel(report(SPAWN, RECV, kill("SIGUSR1"), send(5), WAIT), prog)
    assert said(result) == [1, 1, L["KILL_CAUGHT"], 0, L["WAIT_EXITED"], 1024015]


def test_what_cannot_be_asked_is_refused():
    init = report(
        "li a0, SYS_SIGACTION\n        li a1, SIGKILL\n        li a2, SIG_CATCH\n"
        "        la a3, putn\n        sys",
        action("SIGKILL", "SIG_IGN"),
        action("0", "SIG_IGN"),
        action("NSIG", "SIG_IGN"),
        action("SIGUSR1", "3"),
        action("SIGUSR1", "SIG_IGN"),  # it had its default
        action("SIGUSR1", "SIG_DFL"),  # it was ignored
        sigmask("3", "0"),
        sigmask("SIG_BLOCK", "-1"),
        sigmask("SIG_BLOCK", "1536"),  # SIGKILL and SIGUSR1: SIGKILL stays out
        sigmask("SIG_BLOCK", "0"),
        "li s1, 0\n        " + kill("SIGTERM", on_behalf="KILL_ANY"),  # init
        SPAWN,
        kill("NSIG"),
        kill("-1"),
        kill("0"),  # only asks: it is there
        kill("SIGKILL"),
        WAIT,
    )
    result = run_kernel(init, FOREVER)
    inval = L["E_INVAL"]
    assert said(result) == (
        [inval] * 5
        + [L["SIG_DFL"], L["SIG_IGN"], inval, inval, 0, 1024]
        + [L["E_PERM"], 1, inval, inval, 0, 0, L["WAIT_KILLED"], L["SIGKILL"]]
    )


def test_a_parent_catching_sigchld_hears_its_child_end():
    handler = """
i_h:    sw    a0, i_got
        li    a0, SYS_SIGRETURN
        sys
        .align 1
i_got:  .word 0
"""
    init = report(catch("SIGCHLD", "i_h"), SPAWN, WAIT, "lw a0, i_got", data=handler)
    result = run_kernel(init, "li a1, 3\n        li a0, SYS_EXIT\n        sys")
    assert said(result) == [L["SIG_DFL"], 1, L["WAIT_EXITED"], 3, L["SIGCHLD"]]


def test_an_alarm_can_send_sigalrm():
    prog = """
        csrr  a1, time
        addi  a1, a1, 2000
        li    a2, ALARM_SIGNAL
        li    a0, SYS_ALARM
        sys
1:      j     1b"""
    result = run_kernel(report(SPAWN, WAIT), prog, max_steps=4_000_000)
    assert said(result) == [1, L["WAIT_KILLED"], L["SIGALRM"]]


def test_alarm_refuses_an_unknown_how():
    init = report(
        "li a0, SYS_ALARM\n        li a1, NO_ALARM\n        li a2, 7\n        sys"
    )
    assert said(run_kernel(init)) == [L["E_INVAL"]]


def test_a_child_keeps_the_signals_its_parent_ignores():
    prog = f"{READY}\n        {RECV}\n        mv a1, a0\n        {EXIT_A1}"
    init = report(
        action("SIGTERM", "SIG_IGN"), SPAWN, RECV, kill("SIGTERM"), send(7), WAIT
    )
    result = run_kernel(init, prog)
    assert said(result) == [
        L["SIG_DFL"],
        1,
        1,
        L["KILL_CAUGHT"],
        0,
        L["WAIT_EXITED"],
        7,
    ]


def test_ctrl_c_runs_a_foreground_handler_and_the_program_goes_on():
    # The child catches SIGINT and reads the console once init has given
    # it the console. The Ctrl-C typed ahead reaches it as SIGINT, throws
    # away the "ab" before it, and the read (cut short or not) then gets
    # the "c" after it: exit code SIGINT * 1000 + 'c'.
    prog = child(
        f"""{catch("SIGINT")}
        {READY}
        {RECV}
1:      li    t0, 0
        {GETC}
        li    t0, E_INTR
        beq   a0, t0, 1b
        lw    t0, c_got
        li    t1, 1000
        mul   t0, t0, t1
        add   a1, t0, a0
        {EXIT_A1}"""
    )
    init = f"""
        {SPAWN}
        {RECV}
        CALL_CONSOLE
        li    a2, CN_FOREGROUND
        mv    a3, s1
        sys
        {send(1)}
        {wait_for("s1")}
        li    t0, 10000
        mul   a0, a0, t0
        add   a1, a0, a1
        {EXIT_A1}
"""
    result = run_kernel(init, prog, input="ab" + CTRL_C + "c", console=True)
    # The console server is process 1, so the child is 2; init's code is
    # 10,000 * how the child ended + its code.
    assert result.code_of(2) == L["SIGINT"] * 1000 + ord("c"), result.console
    assert result.code_of(0) == L["SIGINT"] * 1000 + ord("c")


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def test_signals_from_rust(shell):
    result = run_image(
        shell,
        input="rsig\n/bin/kill -l\nexit\n",
        disk=bin_disk(programs=(RSIG,)),
        max_steps=60_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert out.startswith(
        "$ rsig\n"
        "raised 1 10\n"
        "blocked 1\n"
        "unblocked 2 12 had true\n"
        "ignored, was Default\n"
        "kill refused true\n"
        "alarm 1 14\n"
        "thread took it true\n"
        "child killed by SIGINT Some(2) chld 1\n"
        "$ /bin/kill -l\n"
        " 1 HUP\n 2 INT\n"
    ), out


def test_kill_sends_the_signal_it_is_given(shell):
    result = run_image(
        shell,
        input="spin\n"
        + CTRL_C
        + "/bin/kill -USR1 99\n/bin/kill -NOPE 4\n/bin/kill -s HUP\n"
        "/bin/kill -9 4\nps\nexit\n",
        disk=bin_disk(),
        max_steps=60_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert "kill: 99: no such process\nsh: exit 1\n" in out
    assert "kill: -NOPE: no such signal\nsh: exit 2\n" in out
    assert "usage: kill [-SIGNAL] PID... | kill -l\nsh: exit 2\n" in out
    assert "process 4 killed" in result.console  # the pipe server, with SIGKILL


PIPE_WRITE = """
        CALL_PIPE
        li    a2, PP_PIPE
        sys
        li    a0, SYS_CLOSE            # nobody left to read
        li    a1, 0
        sys
        li    a0, SYS_WRITE
        li    a1, 1
        la    a2, c_got
        li    a3, 1
        sys
        mv    a1, a0
        li    a0, SYS_EXIT
        sys"""


def test_a_write_nobody_can_read_sends_sigpipe():
    result = run_kernel(report(SPAWN, WAIT), child(PIPE_WRITE), pipes=True)
    assert said(result)[1:] == [L["WAIT_KILLED"], L["SIGPIPE"]]


def test_a_writer_ignoring_sigpipe_gets_e_pipe():
    prog = child(action("SIGPIPE", "SIG_IGN") + PIPE_WRITE)
    result = run_kernel(report(SPAWN, WAIT), prog, pipes=True)
    assert said(result)[1:] == [L["WAIT_EXITED"], L["E_PIPE"]]


def test_a_pipeline_writer_ended_by_sigpipe_goes_quietly(shell):
    result = run_image(
        shell,
        input="cat notes | head -n 1\nexit\n",
        disk=bin_disk(notes="a line\n" * 400),
        max_steps=60_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert out == "$ cat notes | head -n 1\na line\n$ exit\n"

    # A program in the built-in's place is ended by SIGPIPE, and the
    # shell says nothing of it.
    result = run_image(
        shell,
        input="upper < notes | head -n 1\nexit\n",
        disk=bin_disk(notes="a line\n" * 400),
        max_steps=60_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert out == "$ upper < notes | head -n 1\nA LINE\n$ exit\n"
    assert re.search(r"process \d+ killed", result.console)
