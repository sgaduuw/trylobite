# upper: copy standard input to standard output with a to z made A to Z,
# until the input ends; exit with 0, or with 1 if output fails. A filter,
# for the end of a pipe: hello | upper.

        .include "../include/layout.s"
        .compress
        .section upper, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  UP_MAX, 243              # trytes read at a time

upper:  li    a0, SYS_READ
        li    a1, STDIN
        la    a2, up_buf
        li    a3, UP_MAX
        sys
        blez  a0, 4f                   # the end, or no input
        mv    s0, a0                   # s0: how many
        la    t0, up_buf
        add   t1, t0, s0
1:      lt    t2, 0(t0)
        li    t3, 'a'
        blt   t2, t3, 2f
        li    t3, 'z'
        bgt   t2, t3, 2f
        addi  t2, t2, 'A' - 'a'
        st    t2, 0(t0)
2:      addi  t0, t0, 1
        blt   t0, t1, 1b
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, up_buf
        mv    a3, s0
        sys
        bgez  a0, upper
        li    a1, 1
        j     5f
4:      li    a1, 0
5:      li    a0, SYS_EXIT
        sys

up_buf: .zero UP_MAX
        .nocompress
