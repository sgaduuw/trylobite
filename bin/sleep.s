# sleep TICKS: wait that many ticks of the clock, then exit with 0, as
# Unix's sleep waits seconds. The clock counts one tick per step of the
# machine (detrytus docs/platform.md, Time). Exit with 2 for no number or
# a bad one.

        .include "../include/layout.s"
        .compress
        .section sleep, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  SL_NAN, -1               # sl_atoi: not a number

sleep:  li    t0, 2
        bne   a0, t0, 1f
        lw    a2, 3(a1)
        call  sl_atoi
        bltz  a0, 1f
        csrr  a1, time
        add   a1, a1, a0
        li    a0, SYS_SLEEP
        sys
        li    a1, 0
        li    a0, SYS_EXIT
        sys
1:      la    a2, sl_use
        call  sl_err
        li    a0, SYS_EXIT
        li    a1, 2
        sys

# sl_atoi: a0 = the number the string at a2 writes in decimal, or
# SL_NAN if it is not one (empty, a sign, anything but digits).
# Clobbers t0..t2.
sl_atoi:
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
2:      li    a0, SL_NAN
3:      ret

# sl_err: write the string at a2 to standard error. Clobbers a0..a5, t0.
sl_err:
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

sl_use:     .string "usage: sleep TICKS\n"
        .nocompress
