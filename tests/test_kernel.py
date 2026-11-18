"""trylobite's first milestone: boot, isolation, preemption, messages."""

import re

from detrytus import isa
from detrytus.asm import assemble_file

from tests.kernel import EXIT, ROOT, build, exit_with, run, run_image

DONE = f"li a1, 0\n        {EXIT}"


def test_demo_boots_passes_messages_and_powers_off():
    result = run_image(assemble_file(ROOT / "demo.s"))
    assert result.exit_code == 0
    lines = result.console.splitlines()
    assert lines[0] == "trylobite: booting"
    sent = [ln for ln in lines if ln.startswith("ping: sending")]
    got = [ln for ln in lines if ln.startswith("pong: got")]
    assert sent == [f"ping: sending {n}" for n in (1, 2, 3)]
    assert got == [f"pong: got {n}" for n in (1, 2, 3)]  # in order, none lost
    assert result.exits() == {0: 0, 1: 0}
    assert result.ticks() > 0  # pong's spin was preempted
    assert lines[-1].startswith("trylobite: all processes exited")


def test_the_timer_preempts_a_process_that_never_yields():
    # Process 0 spins forever without a system call. Process 1 can only
    # run if the timer takes the processor away from it.
    spin = "1: j 1b"
    result = run(spin, DONE, max_steps=50_000)
    assert result.exit_code is None  # the spinner keeps the machine alive
    assert result.exits() == {1: 0}


def test_processes_share_virtual_addresses_but_not_memory():
    # Both processes use virtual address V_USER + 3000; process 0 writes 42
    # there and exits, then process 1 reads the same address.
    writer = f"""
        li    t0, V_USER + 3000
        li    t1, 42
        sw    t1, 0(t0)
        lw    t2, 0(t0)
        {exit_with("t2")}
    """
    reader = f"""
        li    a0, SYS_YIELD          # let the writer go first
        sys
        li    t0, V_USER + 3000
        lw    t2, 0(t0)
        {exit_with("t2")}
    """
    assert run(writer, reader).exits() == {0: 42, 1: 0}


def test_a_faulting_process_is_ended_and_the_other_carries_on():
    poke = "li t0, V_CONSOLE\n        lw t1, 0(t0)\n        " + DONE
    result = run(poke, DONE)
    assert result.exit_code == 0
    m = re.search(
        r"process 0 faulted, cause (-?\d+) at address (-?\d+)", result.console
    )
    assert m, result.console
    assert int(m.group(1)) == isa.LOAD_PAGE_FAULT  # a kernel page, from ring -1
    assert int(m.group(2)) == -4 * 19683
    assert result.exits() == {1: 0}


def test_every_exception_reaches_the_kernel_not_the_firmware():
    result = run("brk", DONE)
    assert result.exit_code == 0  # the firmware would power off with cause 5
    assert f"cause {isa.BREAKPOINT} " in result.console


def test_waiting_forever_is_reported_as_deadlock():
    recv = "li a0, SYS_RECV\n        sys\n        " + DONE
    result = run(recv, recv)
    assert result.exit_code == 1
    assert "deadlock" in result.console


def test_a_message_reaches_a_process_already_waiting():
    sender = f"""
        li    a0, SYS_YIELD          # let the receiver block first
        sys
        li    a0, SYS_SEND
        li    a1, 1
        li    a2, 77
        sys
        {exit_with("a0")}
    """
    receiver = f"li a0, SYS_RECV\n        sys\n        {exit_with('a0')}"
    assert run(sender, receiver).exits() == {0: 0, 1: 77}


def test_a_full_mailbox_is_reported():
    sender = """
        li    a0, SYS_SEND
        li    a1, 1
        li    a2, 1
        sys
        li    a0, SYS_SEND
        li    a1, 1
        li    a2, 2
        sys                      # the first is still unread
        mv    a1, a0
        li    a0, SYS_EXIT
        sys
    """
    receiver = "1: li a0, SYS_YIELD\n        sys\n        j 1b"
    assert run(sender, receiver, max_steps=50_000).exits()[0] == -1


def test_system_call_errors():
    bad_pid = "li a0, SYS_SEND\n        li a1, 5\n        sys\n        " + exit_with(
        "a0"
    )
    unknown = "li a0, 99\n        sys\n        " + exit_with("a0")
    assert run(bad_pid, unknown).exits() == {0: -2, 1: -1}


def test_getpid():
    getpid = "li a0, SYS_GETPID\n        sys\n        " + exit_with("a0")
    assert run(getpid, getpid).exits() == {0: 0, 1: 1}


def test_puts_prints_whole_strings_and_refuses_kernel_addresses():
    hello = """
        la    a1, msg
        li    a0, SYS_PUTS
        sys
        mv    a1, a0
        li    a0, SYS_EXIT
        sys
msg:    .string "hello from user space\\n"
    """
    snoop = f"""
        li    a1, V_CONSOLE + 3      # not in this process's page
        li    a0, SYS_PUTS
        sys
        {exit_with("a0")}
    """
    result = run(hello, snoop)
    assert "hello from user space\n" in result.console
    assert result.exits() == {0: 0, 1: -2}


def test_layout_matches_the_register_numbering():
    # The process record stores register r at 3 * (r + 13); the kernel's
    # named offsets must agree with detrytus's register numbers.
    symbols = build(DONE, DONE).symbols
    for name, register in (("PCB_A0", "a0"), ("PCB_A1", "a1"), ("PCB_A2", "a2")):
        assert symbols[name] == 3 * (isa.REG_NAMES[register] + 13)
    assert symbols["PCB_PC"] == 3 * 27  # the first slot after the registers
    assert symbols["PCB_SIZE"] % 3 == 0
