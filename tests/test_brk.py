"""brk: a process's heap, whole pages from HEAP_START (include/layout.s),
which the kernel maps as the process asks and takes back when it ends.
lib/rust/heap.rs builds Rust's allocator on it (tests/test_rust.py)."""

from tests.kernel import exit_with, run, wait_for
from tools import fs

L = fs.L
START = L["HEAP_START"]
PAGE = L["PAGE"]


def brk(end: str) -> str:
    return f"""
        li    a0, SYS_BRK
        li    a1, {end}
        sys"""


def test_the_heap_starts_empty_and_grows_a_page_at_a_time():
    program = f"""
        {brk("BRK_QUERY")}
        mv    s1, a0
        {brk("HEAP_START + 1")}
        sub   a1, a0, s1               # one page
        {exit_with("a1")}
"""
    result = run(program)
    assert result.code_of(0) == PAGE
    program = f"""
        {brk("BRK_QUERY")}
        {exit_with("a0")}
"""
    assert run(program).code_of(0) == START


def test_heap_pages_are_zeroed_and_writable_to_their_last_word():
    program = f"""
        {brk("HEAP_START + PAGE + 1")}  # two pages
        li    t0, HEAP_START + 1
        lw    s1, 0(t0)                # 0: a fresh page
        li    t1, 40
        sw    t1, 0(t0)
        li    t0, HEAP_START + 2 * PAGE - 2   # the second page's last word
        li    t1, 2
        sw    t1, 0(t0)
        lw    a1, 0(t0)
        li    t0, HEAP_START + 1
        lw    t1, 0(t0)
        add   a1, a1, t1
        add   a1, a1, s1
        {exit_with("a1")}
"""
    assert run(program).code_of(0) == 42


def test_it_never_shrinks_and_refuses_ends_outside_it():
    program = f"""
        {brk("HEAP_START + 2 * PAGE")}
        {brk("HEAP_START + 1")}        # inside it: only asks
        li    t0, HEAP_START
        sub   s1, a0, t0
        {brk("HEAP_START - 1")}
        mv    s2, a0
        {brk("HEAP_START + HEAP_MAX * PAGE + 1")}
        add   a1, s2, a0
        li    t0, 1000
        mul   a1, a1, t0
        li    t0, PAGE
        div   s1, s1, t0
        add   a1, a1, s1
        {exit_with("a1")}
"""
    # Two pages, and E_INVAL twice.
    assert run(program).code_of(0) == 2 * L["E_INVAL"] * 1000 + 2


def test_all_the_pages_or_none():
    program = f"""
        {brk("HEAP_START + HEAP_MAX * PAGE")}  # far more than the machine has
        mv    s1, a0
        {brk("BRK_QUERY")}
        li    t0, HEAP_START
        sub   a1, a0, t0               # still empty: 0
        add   a1, a1, s1
        {exit_with("a1")}
"""
    assert run(program).code_of(0) == L["E_NOMEM"]


def test_system_calls_reach_the_heap():
    program = f"""
        {brk("HEAP_START + 1")}
        li    t0, HEAP_START
        li    t1, 'o'
        st    t1, 0(t0)
        li    t1, 'k'
        st    t1, 1(t0)
        li    t1, 10
        st    t1, 2(t0)
        li    a0, SYS_PUTS
        li    a1, HEAP_START
        sys
        {exit_with("a0")}
"""
    result = run(program)
    assert "ok\n" in result.console
    assert result.code_of(0) == 0


def test_the_heap_goes_back_when_the_process_ends():
    # The child grows its heap, tells init, and waits; init reads its
    # pages, ends it and counts the free pages again.
    count = """
        li    a0, SYS_INFO
        la    a1, info
        sys
        la    t0, info
        lw    {reg}, SI_FREE(t0)
"""
    init = f"""
{count.format(reg="s2")}
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s1, a0
        li    a0, SYS_RECV             # it has its heap
        sys
        li    a0, SYS_PROC
        mv    a1, s1
        la    a2, pinfo
        sys
        li    a0, SYS_KILL
        mv    a1, s1
        li    a2, FOR_SELF
        sys
        {wait_for("s1")}
{count.format(reg="s3")}
        la    t0, pinfo
        lw    t1, PI_PAGES(t0)
        li    t0, 1000
        mul   t1, t1, t0
        sub   a1, s3, s2               # 0: all back
        add   a1, a1, t1
        {exit_with("a1")}
info:   .words SYSINFO / 3
pinfo:  .words PROCINFO / 3
"""
    child = f"""
        {brk("HEAP_START + 2 * PAGE + 1")}  # three pages
        li    a0, SYS_SEND
        li    a1, 0
        li    a2, 1
        sys
        li    a0, SYS_RECV             # until it is ended
        sys
"""
    result = run(init, prog1=child)
    assert result.code_of(0) == (L["PAGES_PER_PROCESS"] + 3) * 1000
