# uptime: say how long the machine has run, and how busy it is, on
# standard output, as Unix's uptime does. The machine has no seconds:
# its clock counts ticks, one per step of the machine (detrytus
# docs/platform.md, Time). Exit with 0, or with 1 if output fails.
        .include "../include/layout.s"
        .compress
        .section uptime, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

uptime: la    s8, ut_line              # s8: the end of the line so far
        li    a0, SYS_INFO
        la    a1, ut_info
        sys
        la    a2, ut_up                # up T ticks,
        call  ut_str
        lw    a0, ut_info + SI_TIME
        li    a1, 0
        call  ut_num
        la    a2, ut_ticks
        call  ut_str
        lw    a0, ut_info + SI_PROCS   # P processes,
        li    a1, 0
        call  ut_num
        la    a2, ut_procs
        call  ut_str
        lw    a0, ut_info + SI_HARTS   # H harts
        li    a1, 0
        call  ut_num
        la    a2, ut_harts
        lw    t0, ut_info + SI_HARTS
        li    t1, 1
        bne   t0, t1, 1f
        la    a2, ut_hart
1:      call  ut_str
        call  ut_flush
        lw    a1, ut_status
        li    a0, SYS_EXIT
        sys

# ut_str: append the string at a2 to the line at s8, moving s8 past it.
# Clobbers t0.
ut_str:
1:      lt    t0, 0(a2)
        beqz  t0, 2f
        st    t0, 0(s8)
        addi  a2, a2, 1
        addi  s8, s8, 1
        j     1b
2:      ret

# ut_num: append a0 in decimal to the line at s8, right-aligned in a1
# columns (none if a1 is 0), moving s8 past it. Clobbers t0..t3.
ut_num:
        la    t2, ut_digits_end
        li    t1, 10
        mv    t3, a0
        bgez  t3, 1f
        neg   t3, t3
1:      rem   t0, t3, t1
        addi  t0, t0, '0'
        addi  t2, t2, -1
        st    t0, 0(t2)
        div   t3, t3, t1
        bnez  t3, 1b
        bgez  a0, 1f
        li    t0, '-'
        addi  t2, t2, -1
        st    t0, 0(t2)
1:      la    t3, ut_digits_end
        sub   t1, t3, t2               # t1: its width
        li    t0, ' '
2:      bge   t1, a1, 3f
        st    t0, 0(s8)
        addi  s8, s8, 1
        addi  t1, t1, 1
        j     2b
3:      lt    t0, 0(t2)
        st    t0, 0(s8)
        addi  t2, t2, 1
        addi  s8, s8, 1
        blt   t2, t3, 3b
        ret

# ut_flush: write the line from ut_line to s8 to standard output and
# start a new one; ut_status becomes 1 if that fails. Clobbers a0..a5, t0.
ut_flush:
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, ut_line
        sub   a3, s8, a2
        la    s8, ut_line
        blez  a3, 1f
        sys
        bgez  a0, 1f
        li    t0, 1
        sw    t0, ut_status
1:      ret

        .align 1
ut_status:  .word 0                    # the exit code: 1 once output failed
ut_digits: .zero 12
ut_digits_end:
ut_line:   .zero 243
        .align 1
ut_info:    .words SYSINFO / 3
ut_up:      .string "up "
ut_ticks:   .string " ticks, "
ut_procs:   .string " processes, "
ut_harts:   .string " harts\n"
ut_hart:    .string " hart\n"
        .nocompress
