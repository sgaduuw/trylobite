# ps: say each process on standard output, a line each, as Unix's ps
# does: its number, its parent's, its state, the pages it holds, the
# ticks it has run in user mode and its name. Every process, since there
# are no users or terminals to choose by. Exit with 0, or with 1 if
# output fails.

        .include "../include/layout.s"
        .compress
        .section ps, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

ps:     la    s8, ps_line              # s8: the end of the line so far
        la    a2, ps_head
        call  ps_str
        call  ps_flush
        li    s0, 0                    # s0: the process
1:      li    a0, SYS_PROC
        mv    a1, s0
        la    a2, ps_pi
        sys
        bltz  a0, 2f                   # a free slot
        call  ps_row
        call  ps_flush
2:      addi  s0, s0, 1
        li    t0, NPROC
        blt   s0, t0, 1b
        lw    a1, ps_status
        li    a0, SYS_EXIT
        sys

# ps_row: append process s0's line, from ps_pi, to the line at s8.
# Clobbers a0..a2, t0..t3.
ps_row:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        mv    a0, s0                   # PID
        li    a1, 5
        call  ps_num
        lw    a0, ps_pi + PI_PARENT    # PPID, or - for none
        bgez  a0, 1f
        la    a2, ps_none
        call  ps_str
        j     2f
1:      li    a1, 6
        call  ps_num
2:      li    t0, ' '
        st    t0, 0(s8)
        addi  s8, s8, 1
        lw    t0, ps_pi + PI_STATE     # STATE
        li    t1, PS_ST_FIRST
        sub   t0, t0, t1
        li    t1, PS_ST_NAME
        mul   t0, t0, t1
        la    a2, ps_states
        add   a2, a2, t0
        call  ps_str
        lw    a0, ps_pi + PI_PAGES     # PAGES
        li    a1, 6
        call  ps_num
        lw    a0, ps_pi + PI_CPU       # TIME
        li    a1, 11
        call  ps_num
        li    t0, ' '
        st    t0, 0(s8)
        addi  s8, s8, 1
        la    a2, ps_pi + PI_NAME      # NAME, or - for none
        lt    t0, 0(a2)
        bnez  t0, 3f
        la    a2, ps_dash
3:      call  ps_str
        li    t0, '\n'
        st    t0, 0(s8)
        addi  s8, s8, 1
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# ps_str: append the string at a2 to the line at s8, moving s8 past it.
# Clobbers t0.
ps_str:
1:      lt    t0, 0(a2)
        beqz  t0, 2f
        st    t0, 0(s8)
        addi  a2, a2, 1
        addi  s8, s8, 1
        j     1b
2:      ret

# ps_num: append a0 in decimal to the line at s8, right-aligned in a1
# columns (none if a1 is 0), moving s8 past it. Clobbers t0..t3.
ps_num:
        la    t2, ps_digits_end
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
1:      la    t3, ps_digits_end
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

# ps_flush: write the line from ps_line to s8 to standard output and
# start a new one; ps_status becomes 1 if that fails. Clobbers a0..a5, t0.
ps_flush:
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, ps_line
        sub   a3, s8, a2
        la    s8, ps_line
        blez  a3, 1f
        sys
        bgez  a0, 1f
        li    t0, 1
        sw    t0, ps_status
1:      ret

# ps_states: each state's name, by ST_ value from PS_ST_FIRST, in
# PS_ST_NAME trytes each (padded to the column, then a 0).
        .equ  PS_ST_FIRST, ST_SLEEP
        .equ  PS_ST_LAST, ST_RUNNING
        .equ  PS_ST_NAME, 8
ps_states:
        .ascii "sleep  "
        .tryte 0                       # -11
        .ascii "lookup "
        .tryte 0                       # -10
        .ascii "receive"
        .tryte 0                       # -9
        .ascii "reply  "
        .tryte 0                       # -8
        .ascii "call   "
        .tryte 0                       # -7
        .ascii "?      "
        .tryte 0                       # -6
        .ascii "?      "
        .tryte 0                       # -5
        .ascii "?      "
        .tryte 0                       # -4
        .ascii "zombie "
        .tryte 0                       # -3
        .ascii "wait   "
        .tryte 0                       # -2
        .ascii "recv   "
        .tryte 0                       # -1
        .ascii "?      "
        .tryte 0                       # 0
        .ascii "ready  "
        .tryte 0                       # 1
        .ascii "run    "
        .tryte 0                       # 2

        .align 1
ps_status:  .word 0                    # the exit code: 1 once output failed
ps_digits: .zero 12
ps_digits_end:
ps_line:   .zero 243
ps_pi:      .words PROCINFO / 3
ps_head:    .string "  PID  PPID STATE    PAGES       TIME NAME\n"
ps_none:    .string "     -"
ps_dash:    .string "-"
        .nocompress
