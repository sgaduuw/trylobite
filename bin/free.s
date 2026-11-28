# free: say how much memory there is, how much is in use and how much
# is free, in pages and in trytes, on standard output, as Unix's free
# does. In use is everything not free: the kernel, the program images,
# the kernel's log and every process's pages. Exit with 0, or with 1 if
# output fails.
        .include "../include/layout.s"
        .compress
        .section free, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  FR_COL, 12               # columns for each number: room for
                                       # MEM_MAX pages in trytes and a space

free:   la    s8, fr_line              # s8: the end of the line so far
        li    a0, SYS_INFO
        la    a1, fr_info
        sys
        la    a2, fr_head
        call  fr_str
        call  fr_flush
        li    s0, 1                    # s0: trytes per unit: pages first
        la    a2, fr_pages
1:      call  fr_str
        lw    a0, fr_info + SI_PAGES
        mul   a0, a0, s0
        li    a1, FR_COL
        call  fr_num
        lw    a0, fr_info + SI_PAGES
        lw    t0, fr_info + SI_FREE
        sub   a0, a0, t0
        mul   a0, a0, s0
        li    a1, FR_COL
        call  fr_num
        lw    a0, fr_info + SI_FREE
        mul   a0, a0, s0
        li    a1, FR_COL
        call  fr_num
        li    t0, '\n'
        st    t0, 0(s8)
        addi  s8, s8, 1
        call  fr_flush
        li    t0, PAGE
        beq   s0, t0, 2f
        mv    s0, t0                   # then trytes
        la    a2, fr_trytes
        j     1b
2:      lw    a1, fr_status
        li    a0, SYS_EXIT
        sys

# fr_str: append the string at a2 to the line at s8, moving s8 past it.
# Clobbers t0.
fr_str:
1:      lt    t0, 0(a2)
        beqz  t0, 2f
        st    t0, 0(s8)
        addi  a2, a2, 1
        addi  s8, s8, 1
        j     1b
2:      ret

# fr_num: append a0 in decimal to the line at s8, right-aligned in a1
# columns (none if a1 is 0), moving s8 past it. Clobbers t0..t3.
fr_num:
        la    t2, fr_digits_end
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
1:      la    t3, fr_digits_end
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

# fr_flush: write the line from fr_line to s8 to standard output and
# start a new one; fr_status becomes 1 if that fails. Clobbers a0..a5, t0.
fr_flush:
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, fr_line
        sub   a3, s8, a2
        la    s8, fr_line
        blez  a3, 1f
        sys
        bgez  a0, 1f
        li    t0, 1
        sw    t0, fr_status
1:      ret

        .align 1
fr_status:  .word 0                    # the exit code: 1 once output failed
fr_digits: .zero 12
fr_digits_end:
fr_line:   .zero 243
        .align 1
fr_info:    .words SYSINFO / 3
fr_head:    .string "               total        used        free\n"
fr_pages:   .string "pages:  "
fr_trytes:  .string "trytes: "
        .nocompress
