# wc: count the lines, words and code points of standard input, and say
# them on standard output, as Unix's wc does; exit with 0, or with 1 if
# output fails. A filter, for the end of a pipe: ls | wc.

        .include "../include/layout.s"
        .compress
        .section wc, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  WC_MAX, 243              # trytes read at a time

wc:     li    s0, 0                    # s0: lines
        li    s1, 0                    # s1: words
        li    s2, 0                    # s2: code points
        li    s3, 0                    # s3: 1 inside a word
1:      li    a0, SYS_READ
        li    a1, STDIN
        la    a2, wc_buf
        li    a3, WC_MAX
        sys
        blez  a0, 5f                   # the end, or no input
        add   s2, s2, a0
        la    t0, wc_buf
        add   t1, t0, a0
2:      lt    t2, 0(t0)
        li    t3, '\n'
        bne   t2, t3, 3f
        addi  s0, s0, 1
3:      li    t3, ' '                  # a space, or a control character
        bgt   t2, t3, 4f               # such as a newline or tab, ends a word
        li    s3, 0
        j     6f
4:      bnez  s3, 6f                   # a word starts
        li    s3, 1
        addi  s1, s1, 1
6:      addi  t0, t0, 1
        blt   t0, t1, 2b
        j     1b

5:      la    s4, wc_out               # s4: where the next number goes
        mv    a0, s0
        call  wc_num
        mv    a0, s1
        call  wc_num
        mv    a0, s2
        call  wc_num
        li    t0, '\n'                 # the last space becomes a newline
        st    t0, -1(s4)
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, wc_out
        la    t0, wc_out
        sub   a3, s4, t0
        sys
        li    a1, 0
        bgez  a0, 7f
        li    a1, 1
7:      li    a0, SYS_EXIT
        sys

# wc_num: put a0, which is not negative, at s4 in decimal and a space, and
# move s4 past them. Clobbers t0..t3.
wc_num: la    t2, wc_digits_end
        li    t1, 10
1:      rem   t0, a0, t1
        addi  t0, t0, '0'
        addi  t2, t2, -1
        st    t0, 0(t2)
        div   a0, a0, t1
        bnez  a0, 1b
        la    t3, wc_digits_end
2:      lt    t0, 0(t2)
        st    t0, 0(s4)
        addi  t2, t2, 1
        addi  s4, s4, 1
        blt   t2, t3, 2b
        li    t0, ' '
        st    t0, 0(s4)
        addi  s4, s4, 1
        ret

wc_buf: .zero WC_MAX
wc_digits: .zero 12
wc_digits_end:
wc_out: .zero 40
        .nocompress
