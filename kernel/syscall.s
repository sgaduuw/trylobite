# System calls, and ending a process. The Rust chooses the routine for
# each number and runs it (kernel/rust/trykern/src/syscall.rs); the
# routine leaves the result in the caller's saved a0 and says what comes
# next: 0 the caller goes on, 1 another process runs, 2 the caller has
# ended.

        .compress
on_syscall:
        csrr  t0, stval                # the instruction after the sys: tpc + 3
        sw    t0, PCB_PC(s0)           # is wrong when the sys is in a bundle
syscall_again:                         # resume runs a call again (retry)
        mv    a0, s0
        call  rk_syscall
        beqz  a0, resume
        li    t0, 1
        beq   a0, t0, schedule

# release: end the process in s0, return its pages, and bury it (mm.rs,
# wait.rs). Its saved a0 and a1 say how it ended. It leaves its address
# space first: freeing a page writes the free-list link into its centre
# word, which in a root table is entry 0, and done while that table is
# live the next walk would read garbage. Does not return.
release:
        li    t0, PTBR_BOOT
        csrw  ptbr, t0
        mv    a0, s0
        call  rk_release
        j     schedule
        .nocompress
