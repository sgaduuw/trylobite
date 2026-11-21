"""Boot, isolation, preemption, faults and messages."""

import re

from tests.kernel import (
    BREAKPOINT,
    DONE,
    LOAD_PAGE_FAULT,
    REGISTERS,
    ROOT,
    SPAWN_BOTH,
    assemble_file,
    build,
    detrytus,
    exit_with,
    run,
    run_image,
    send_to_2,
)


def test_demo_boots_spawns_passes_messages_and_powers_off():
    result = run_image(assemble_file(ROOT / "demo.s"))
    assert result.exit_code == 0
    lines = result.console.splitlines()
    assert lines[:2] == ["trylobite: booting", "init: starting pong and ping"]
    sent = [ln for ln in lines if ln.startswith("ping: sending")]
    got = [ln for ln in lines if ln.startswith("pong: got")]
    assert sent == [f"ping: sending {n}" for n in (1, 2, 3)]
    assert got == [f"pong: got {n}" for n in (1, 2, 3)]  # in order, none lost
    assert sorted(result.exits()) == [(0, 0), (1, 0), (2, 0)]
    assert result.ticks() > 0  # pong's spin was preempted
    assert lines[-1].startswith("trylobite: all processes exited")


def test_the_timer_preempts_a_process_that_never_yields():
    # Program 1 spins forever without a system call. Program 2 can only
    # run if the timer takes the processor away from it.
    result = run(SPAWN_BOTH, "1: j 1b", DONE, max_steps=400_000)
    assert result.exit_code is None  # the spinner keeps the machine alive
    assert result.code_of(2) == 0


def test_processes_share_virtual_addresses_but_not_memory():
    # Both use virtual address V_USER + 3000; program 1 writes 42 there and
    # exits, then program 2 reads the same address.
    writer = f"""
        li    t0, V_USER + 3000
        li    t1, 42
        sw    t1, 0(t0)
        lw    t2, 0(t0)
        {exit_with("t2")}
    """
    reader = f"""
        li    a0, SYS_YIELD
        sys
        li    t0, V_USER + 3000
        lw    t2, 0(t0)
        {exit_with("t2")}
    """
    result = run(SPAWN_BOTH, writer, reader)
    assert (result.code_of(1), result.code_of(2)) == (42, 0)


def test_a_faulting_process_is_ended_and_the_others_carry_on():
    poke = "li t0, V_CONSOLE\n        lw t1, 0(t0)\n        " + DONE
    result = run(SPAWN_BOTH, poke, DONE)
    assert result.exit_code == 0
    m = re.search(
        r"process 1 faulted, cause (-?\d+) at address (-?\d+)", result.console
    )
    assert m, result.console
    assert int(m.group(1)) == LOAD_PAGE_FAULT  # a kernel page, from ring -1
    assert int(m.group(2)) == -4 * 19683
    assert result.code_of(2) == 0


def test_every_exception_reaches_the_kernel_not_the_firmware():
    result = run(SPAWN_BOTH, "brk", DONE)
    assert result.exit_code == 0  # the firmware would power off with cause 5
    assert f"cause {BREAKPOINT} " in result.console


def test_waiting_forever_is_reported_as_deadlock():
    recv = "li a0, SYS_RECV\n        sys\n        " + DONE
    result = run(SPAWN_BOTH, recv, recv)
    assert result.exit_code == 1
    assert "deadlock" in result.console


def test_a_message_reaches_a_process_already_waiting():
    sender = f"""
        li    a0, SYS_YIELD          # let the receiver block first
        sys
        {send_to_2(77)}
        {exit_with("a0")}
    """
    receiver = f"li a0, SYS_RECV\n        sys\n        {exit_with('a0')}"
    result = run(SPAWN_BOTH, sender, receiver)
    assert (result.code_of(1), result.code_of(2)) == (0, 77)


def test_a_full_mailbox_is_reported():
    sender = f"""
        {send_to_2(1)}
        li    a0, SYS_SEND
        li    a1, 2
        li    a2, 2
        sys                      # the first is still unread
        {exit_with("a0")}
    """
    receiver = "1: li a0, SYS_YIELD\n        sys\n        j 1b"
    assert run(SPAWN_BOTH, sender, receiver, max_steps=400_000).code_of(1) == -1


def test_system_call_errors():
    bad_pid = "li a0, SYS_SEND\n        li a1, 5\n        sys\n        " + exit_with(
        "a0"
    )
    unknown = "li a0, 99\n        sys\n        " + exit_with("a0")
    result = run(SPAWN_BOTH, bad_pid, unknown)
    assert (result.code_of(1), result.code_of(2)) == (-2, -1)


def test_getpid():
    getpid = "li a0, SYS_GETPID\n        sys\n        " + exit_with("a0")
    result = run(SPAWN_BOTH, getpid, getpid)
    assert (result.code_of(1), result.code_of(2)) == (1, 2)


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
    result = run(SPAWN_BOTH, hello, snoop)
    assert "hello from user space\n" in result.console
    assert (result.code_of(1), result.code_of(2)) == (0, -2)


def test_layout_matches_the_register_numbering():
    # The process record stores register r at 3 * (r + 13); the kernel's
    # named offsets must agree with detrytus's register numbers.
    symbols = build(DONE).symbols
    for name, register in (("PCB_A0", "a0"), ("PCB_A1", "a1"), ("PCB_A2", "a2")):
        assert symbols[name] == 3 * (REGISTERS[register] + 13)
    assert symbols["PCB_PC"] == 3 * 27  # the first slot after the registers
    assert symbols["PCB_SIZE"] % 3 == 0


def test_labels_are_the_addresses_code_runs_at():
    image = build(DONE)
    k = image.symbols
    # The kernel loads into physical page P_KCODE but runs KOFF lower.
    assert image.labels["kentry"] < 0
    assert image.labels["kentry"] == k["P_KCODE"] * k["PAGE"] - 9840 - k["KOFF"]
    load = image.labels["kentry"] + k["KOFF"]
    assert load in image.trytes  # the code itself sits at the load address
    assert image.labels["procs"] % 3 == 0  # .words: a word-aligned table


def test_the_kernel_alone_says_how_to_build_it():
    # include/kernel.s has no RAM_PAGES and no programs: assembled on its
    # own, the first error should point at a file to run instead.
    done = detrytus("asm", "include/kernel.s")
    assert done.returncode != 0
    assert "include/kernel.s is not run on its own" in done.stderr
    assert "such as demo.s or shell.s" in done.stderr
