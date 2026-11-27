"""What the kernel tells system tools about itself (kernel/info.s,
kernel/proc.s): its log, a summary of the machine, each process, a
process's name and the user-mode ticks it ran; and waiting for the clock
(sleep), and kill from any process."""

from tests.kernel import RAM_PAGES, run
from tests.test_files import L, report, said

LOG_SIZE = L["PAGE"]
WORDS = """
        .align 1
info:   .words SYSINFO / 3
pinfo:  .words PROCINFO / 3
"""


def info(at: str = "info") -> str:
    load = "la" if at.startswith("info") else "li"  # a label, or an address
    return f"""
        li    a0, SYS_INFO
        {load}    a1, {at}
        sys"""


def word(label: str, offset: str) -> str:
    return f"        lw    a0, {label} + {offset}"


def puts(label: str) -> str:
    return f"""
        li    a0, SYS_PUTS
        la    a1, {label}
        sys"""


# --- info --------------------------------------------------------------------


def test_info_says_memory_the_process_table_and_harts():
    from tests import kernel

    program = report(
        info(),
        word("info", "SI_PAGES"),
        word("info", "SI_NPROC"),
        word("info", "SI_PROCS"),
        word("info", "SI_HARTS"),
        word("info", "SI_TIME") + "\n        cmp   a0, a0, zero",
        f"""{word("info", "SI_FREE")}
        li    t0, {RAM_PAGES}
        cmp   a0, t0, a0""",
        puts("info + SI_RELEASE"),
        data=WORDS,
    )
    result = run(program)
    assert said(result)[:7] == [0, RAM_PAGES, 27, 1, kernel.HARTS, 1, 1]
    assert "0.1.0" in result.console


def test_memory_is_what_the_machine_has():
    # The kernel reads the RAM size register at boot: a build runs on a
    # machine of any size, and boot touches none of the free pages.
    program = report(
        info(),
        word("info", "SI_PAGES"),
        f"""{word("info", "SI_FREE")}
        lw    t0, info + SI_PAGES
        sub   a0, t0, a0""",
        data=WORDS,
    )
    used = said(run(program))[2]
    for pages in (RAM_PAGES + 1, 100_000):
        assert said(run(program, ram_pages=pages)) == [0, pages, used]


def test_ram_past_the_direct_map_goes_unused():
    # The direct map takes mid entries -16 to -1 and reaches page MEM_MAX;
    # the machine may have more (detrytus allows every positive page),
    # which the kernel leaves alone.
    program = report(info(), word("info", "SI_PAGES"), data=WORDS)
    biggest = (3**18 - 1) // 2
    assert said(run(program, ram_pages=biggest)) == [0, L["MEM_MAX"]]
    assert said(run(program, ram_pages=L["MEM_MAX"])) == [0, L["MEM_MAX"]]


def test_info_wants_a_whole_aligned_buffer_of_its_own():
    program = report(
        info("info + 1"),
        info("V_USER + 9840"),  # runs off the end of the page
        info("0"),
        data=WORDS,
    )
    assert said(run(program)) == [L["E_FAULT"]] * 3


# --- the log -----------------------------------------------------------------


def log(buf: str, n: str, start: str) -> str:
    return f"""
        li    a0, SYS_LOG
        la    a1, {buf}
        li    a2, {n}
        mv    a3, {start}
        sys"""


def test_the_log_gives_back_what_the_kernel_printed():
    # Find where the log is now (a read far ahead gets nothing and says
    # where it stands), print, and read back from there.
    program = f"""
        .gp   USER_GP
        li    s0, 1000000000
{log("buf", "0", "s0")}
        mv    s5, a1                   # s5: where the log stands
{puts("text")}
{log("buf", "243", "s5")}
        mv    s6, a0                   # how many
{puts("buf")}
        li    s0, -5                   # before the start: from the oldest
{log("buf", "9", "s0")}
        li    t0, 9
        bne   a0, t0, 9f
        bne   a1, t0, 9f
{puts("buf")}
        li    s0, 0
{log("buf", "-1", "s0")}
        li    t0, E_INVAL
        bne   a0, t0, 9f
        mv    a1, s6
        li    a0, SYS_EXIT
        sys
9:      li    a1, 99
        li    a0, SYS_EXIT
        sys
text:   .string "a line\\n"
buf:    .zero 300
"""
    result = run(program)
    assert result.code_of(0) == 7
    assert "a line\na line\ntrylobite" in result.console


def test_the_log_keeps_the_last_page_of_it():
    # Print more than the log keeps: a reader from the start then gets the
    # oldest it still has, LOG_SIZE behind where it stands.
    program = f"""
        .gp   USER_GP
        li    s1, 260                  # 260 lines of 81: more than a page
1:
{puts("line")}
        addi  s1, s1, -1
        bnez  s1, 1b
        li    s0, 1000000000
{log("buf", "0", "s0")}
        mv    s5, a1                   # s5: where it stands
        li    s0, 0
{log("buf", "20", "s0")}
        sub   a1, s5, a1               # how far behind the oldest is
        li    a0, SYS_EXIT
        sys
line:   .string "{"x" * 80}\\n"
buf:    .zero 30
"""
    assert run(program, max_steps=4_000_000).code_of(0) == LOG_SIZE - 20


# --- processes -----------------------------------------------------------------


def proc(pid: str, at: str = "pinfo") -> str:
    load = "la" if at.startswith("pinfo") else "li"
    return f"""
        li    a0, SYS_PROC
        li    a1, {pid}
        {load}    a2, {at}
        sys"""


def test_proc_says_a_process_and_name_names_it():
    program = report(
        """
        li    a0, SYS_NAME
        la    a1, long
        sys""",
        proc("0"),
        word("pinfo", "PI_STATE"),
        word("pinfo", "PI_PARENT"),
        word("pinfo", "PI_PAGES"),
        puts("pinfo + PI_NAME"),
        data=WORDS + 'long:   .string "/bin/a/abcdefghijk"\n',
    )
    result = run(program)
    assert said(result)[:5] == [0, 0, L["ST_RUNNING"], L["NO_PARENT"], 4]
    assert "abcdefgh0 " in result.console  # its last part, cut to 8; then 0


def test_proc_refuses_free_slots_and_bad_buffers():
    program = report(
        proc("1"),
        proc("-1"),
        proc("NPROC"),
        proc("0", "pinfo + 1"),
        proc("0", "V_USER + 9840"),
        data=WORDS,
    )
    assert said(run(program)) == [L["E_NOPROC"]] * 3 + [L["E_FAULT"]] * 2


def test_proc_counts_the_ticks_each_process_runs():
    # Program 1 spins; init sleeps meanwhile, so it runs far less.
    init = f"""
        .gp   USER_GP
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        csrr  a1, time
        li    t0, 300000
        add   a1, a1, t0
        li    a0, SYS_SLEEP
        sys
{proc("1")}
        lw    s1, pinfo + PI_CPU       # s1: the spinner's ticks
{proc("0")}
        lw    s2, pinfo + PI_CPU       # s2: init's
        li    a0, SYS_KILL
        li    a1, 1
        li    a2, FOR_SELF
        sys
        li    s3, 0
        li    t0, 100000
        blt   s1, t0, 1f
        blt   s2, t0, 2f
1:      li    s3, 99
2:      mv    a1, s3
        li    a0, SYS_EXIT
        sys
{WORDS}"""
    spin = "1:      j     1b"
    assert run(init, spin, max_steps=4_000_000).code_of(0) == 0


# --- sleep ---------------------------------------------------------------------


def test_sleep_waits_for_the_clock_and_is_not_a_deadlock():
    # The only process sleeps: nothing runs or waits for anything else,
    # which without sleep in the kernel's reckoning would read as stuck.
    program = """
        .gp   USER_GP
        csrr  s0, time
        li    t0, 200000
        add   s0, s0, t0
        mv    a1, s0
        li    a0, SYS_SLEEP
        sys
        mv    s1, a0
        csrr  t0, time
        li    a1, 1
        blt   t0, s0, 1f               # woken early
        li    a1, 0
1:      add   a1, a1, s1
        li    a0, SYS_SLEEP            # a time gone by: at once
        li    a1, 0
        sys
        add   a1, a1, a0
        li    a0, SYS_EXIT
        sys
"""
    result = run(program)
    assert result.code_of(0) == 0
    assert "all processes exited" in result.console


def test_a_sleeper_can_be_killed():
    init = """
        .gp   USER_GP
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s0, a0
        li    a0, SYS_YIELD            # let it fall asleep
        sys
        li    a0, SYS_KILL
        mv    a1, s0
        li    a2, FOR_SELF
        sys
        li    a0, SYS_WAIT
        mv    a1, s0
        sys
        mv    a1, a0                   # how it ended
        li    a0, SYS_EXIT
        sys
"""
    sleeper = """
        li    a1, 1000000000
        li    a0, SYS_SLEEP
        sys
        li    a1, 5
        li    a0, SYS_EXIT
        sys
"""
    result = run(init, sleeper)
    assert result.code_of(0) == L["WAIT_KILLED"]
    assert "process 1 killed" in result.console


# --- kill ----------------------------------------------------------------------


def test_kill_any_ends_a_process_that_is_not_its_child():
    # Program 2 ends program 1, its sibling, and may not end init.
    init = """
        .gp   USER_GP
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        li    a0, SYS_SPAWN
        li    a1, 2
        sys
        li    a0, SYS_WAIT
        li    a1, 2
        sys
        li    a0, SYS_WAIT
        li    a1, 1
        sys
        mv    a1, a0                   # how it ended
        li    a0, SYS_EXIT
        sys
"""
    waits = "li a0, SYS_RECV\n        sys\n        li a0, SYS_EXIT\n        sys"
    killer = report(
        *(
            f"""
        li    a0, SYS_KILL
        li    a1, {pid}
        li    a2, KILL_ANY
        sys"""
            for pid in ("1", "0", "5", "-1")
        )
    )
    result = run(init, waits, killer)
    assert said(result)[:4] == [0, L["E_PERM"], L["E_NOPROC"], L["E_NOPROC"]]
    assert result.code_of(0) == L["WAIT_KILLED"]
    assert "process 1 killed" in result.console
