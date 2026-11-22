# top [-n COUNT]: show the processes and how busy each is, again every
# TP_PERIOD ticks, as Unix's top does: a summary line, then a line per
# process with the share of the clock it ran in user mode since the last
# screen (CPU%; with several harts the shares can add up past 100). Each
# screen first clears the terminal (ANSI: cursor home, erase all).
# COUNT screens, or until Ctrl-C ends it. Exit with 0, with 1 if output
# fails, or with 2 for a bad argument.

        .include "../include/layout.s"
        .compress
        .section top, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  TP_PERIOD, 1000000       # ticks between screens
        .equ  TP_NAN, -1               # tp_atoi: not a number
        .equ  TP_FOREVER, -1           # tp_left: no COUNT, so no end

top:    la    s8, tp_line              # s8: the end of the line so far
        li    t0, 1
        beq   a0, t0, 2f
        li    t0, 3
        bne   a0, t0, tp_usage
        lw    a2, 3(a1)                # -n COUNT
        la    t1, tp_dashn
1:      lt    t0, 0(a2)
        lt    t2, 0(t1)
        bne   t0, t2, tp_usage
        addi  a2, a2, 1
        addi  t1, t1, 1
        bnez  t0, 1b
        lw    a2, 6(a1)
        call  tp_atoi
        blez  a0, tp_usage
        sw    a0, tp_left
2:      csrr  s7, time                 # s7: when the next screen is due

tp_screen:
        li    a0, SYS_INFO
        la    a1, tp_info
        sys
        lw    s5, tp_info + SI_TIME    # s5: the clock now
        lw    t0, tp_then
        sub   s4, s5, t0               # s4: ticks since the last screen
        sw    s5, tp_then
        la    a2, tp_clear
        call  tp_str
        la    a2, tp_up                # top: up T ticks,
        call  tp_str
        mv    a0, s5
        li    a1, 0
        call  tp_num
        la    a2, tp_ticks
        call  tp_str
        lw    a0, tp_info + SI_PROCS   # P processes,
        li    a1, 0
        call  tp_num
        la    a2, tp_procs
        call  tp_str
        lw    a0, tp_info + SI_HARTS   # H harts,
        li    a1, 0
        call  tp_num
        la    a2, tp_harts
        lw    t0, tp_info + SI_HARTS
        li    t1, 1
        bne   t0, t1, 0f
        la    a2, tp_hart
0:      call  tp_str
        lw    a0, tp_info + SI_FREE    # F of N pages free
        li    a1, 0
        call  tp_num
        la    a2, tp_of
        call  tp_str
        lw    a0, tp_info + SI_PAGES
        li    a1, 0
        call  tp_num
        la    a2, tp_free
        call  tp_str
        call  tp_flush
        li    s0, 0                    # s0: the process
        la    s1, tp_last              # s1: its ticks at the last screen
1:      li    a0, SYS_PROC
        mv    a1, s0
        la    a2, tp_pi
        sys
        lw    t1, tp_pi + PI_CPU
        bgez  a0, 0f
        li    t1, 0                    # a free slot: a new process starts at 0
0:      lw    t0, 0(s1)
        sw    t1, 0(s1)
        bltz  a0, 3f
        sub   s6, t1, t0               # s6: its share of the clock
        bgez  s6, 0f
        mv    s6, t1                   # a new tenant of the slot
0:      li    t0, 1000                 # in tenths of a percent
        mul   s6, s6, t0
        blez  s4, 0f
        div   s6, s6, s4
0:      call  tp_row
        call  tp_flush
3:      addi  s0, s0, 1
        addi  s1, s1, 3
        li    t0, NPROC
        blt   s0, t0, 1b
        lw    t0, tp_left
        bltz  t0, 4f                   # TP_FOREVER
        addi  t0, t0, -1
        sw    t0, tp_left
        beqz  t0, tp_end
4:      li    t0, TP_PERIOD
        add   s7, s7, t0
        li    a0, SYS_SLEEP
        mv    a1, s7
        sys
        j     tp_screen

tp_end: lw    a1, tp_status
        li    a0, SYS_EXIT
        sys

tp_usage:
        la    a2, tp_use
        call  tp_err
        li    a0, SYS_EXIT
        li    a1, 2
        sys

# tp_row: append process s0's line, from tp_pi, to the line at s8.
# Clobbers a0..a2, t0..t3.
tp_row:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        mv    a0, s0                   # PID
        li    a1, 5
        call  tp_num
        lw    a0, tp_pi + PI_PARENT    # PPID, or - for none
        bgez  a0, 1f
        la    a2, tp_none
        call  tp_str
        j     2f
1:      li    a1, 6
        call  tp_num
2:      li    t0, ' '
        st    t0, 0(s8)
        addi  s8, s8, 1
        lw    t0, tp_pi + PI_STATE     # STATE
        li    t1, TP_ST_FIRST
        sub   t0, t0, t1
        li    t1, TP_ST_NAME
        mul   t0, t0, t1
        la    a2, tp_states
        add   a2, a2, t0
        call  tp_str
        lw    a0, tp_pi + PI_PAGES     # PAGES
        li    a1, 6
        call  tp_num
        li    t0, 10                   # CPU%, s6 in tenths of one
        div   a0, s6, t0
        li    a1, 5
        call  tp_num
        li    t0, '.'
        st    t0, 0(s8)
        li    t0, 10
        rem   t0, s6, t0
        addi  t0, t0, '0'
        st    t0, 1(s8)
        addi  s8, s8, 2
        lw    a0, tp_pi + PI_CPU       # TIME
        li    a1, 11
        call  tp_num
        li    t0, ' '
        st    t0, 0(s8)
        addi  s8, s8, 1
        la    a2, tp_pi + PI_NAME      # NAME, or - for none
        lt    t0, 0(a2)
        bnez  t0, 3f
        la    a2, tp_dash
3:      call  tp_str
        li    t0, '\n'
        st    t0, 0(s8)
        addi  s8, s8, 1
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# tp_str: append the string at a2 to the line at s8, moving s8 past it.
# Clobbers t0.
tp_str:
1:      lt    t0, 0(a2)
        beqz  t0, 2f
        st    t0, 0(s8)
        addi  a2, a2, 1
        addi  s8, s8, 1
        j     1b
2:      ret

# tp_num: append a0 in decimal to the line at s8, right-aligned in a1
# columns (none if a1 is 0), moving s8 past it. Clobbers t0..t3.
tp_num:
        la    t2, tp_digits_end
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
1:      la    t3, tp_digits_end
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

# tp_flush: write the line from tp_line to s8 to standard output and
# start a new one; tp_status becomes 1 if that fails. Clobbers a0..a5, t0.
tp_flush:
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, tp_line
        sub   a3, s8, a2
        la    s8, tp_line
        blez  a3, 1f
        sys
        bgez  a0, 1f
        li    t0, 1
        sw    t0, tp_status
1:      ret

# tp_states: each state's name, by ST_ value from TP_ST_FIRST, in
# TP_ST_NAME trytes each (padded to the column, then a 0).
        .equ  TP_ST_FIRST, ST_SLEEP
        .equ  TP_ST_LAST, ST_RUNNING
        .equ  TP_ST_NAME, 8
tp_states:
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

# tp_atoi: a0 = the number the string at a2 writes in decimal, or
# TP_NAN if it is not one (empty, a sign, anything but digits).
# Clobbers t0..t2.
tp_atoi:
        li    a0, 0
        lt    t0, 0(a2)
        beqz  t0, 2f                   # empty
1:      lt    t0, 0(a2)
        beqz  t0, 3f
        addi  t0, t0, -'0'
        bltz  t0, 2f
        li    t1, 9
        bgt   t0, t1, 2f
        li    t1, 10
        mul   a0, a0, t1
        add   a0, a0, t0
        addi  a2, a2, 1
        j     1b
2:      li    a0, TP_NAN
3:      ret

# tp_err: write the string at a2 to standard error. Clobbers a0..a5, t0.
tp_err:
        mv    a3, a2
1:      lt    t0, 0(a3)
        beqz  t0, 2f
        addi  a3, a3, 1
        j     1b
2:      sub   a3, a3, a2
        li    a0, SYS_WRITE
        li    a1, STDERR
        sys
        ret

        .align 1
tp_status:  .word 0                    # the exit code: 1 once output failed
tp_digits: .zero 12
tp_digits_end:
tp_line:   .zero 300
        .align 1
tp_left:    .word TP_FOREVER           # screens still to show
tp_then:    .word 0                    # the clock at the last screen
tp_info:    .words SYSINFO / 3
tp_pi:      .words PROCINFO / 3
tp_last:    .words NPROC               # each slot's ticks at the last screen
tp_clear:   .tryte 27
            .ascii "[H"
            .tryte 27
            .string "[2J"
tp_up:      .string "top: up "
tp_ticks:   .string " ticks, "
tp_procs:   .string " processes, "
tp_harts:   .string " harts, "
tp_hart:    .string " hart, "
tp_of:      .string " of "
tp_free:    .string " pages free\n\n  PID  PPID STATE    PAGES   CPU%       TIME NAME\n"
tp_none:    .string "     -"
tp_dash:    .string "-"
tp_dashn:   .string "-n"
tp_use:     .string "usage: top [-n COUNT]\n"
        .nocompress
