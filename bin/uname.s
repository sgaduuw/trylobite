# uname [-a]: say the system's name on standard output, as Unix's uname
# does; with -a also the kernel's version and the machine. Exit with 0,
# with 1 if output fails, or with 2 for an argument it does not know
# (said on standard error).
        .include "../include/layout.s"
        .compress
        .section uname, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

uname:  la    s8, un_line              # s8: the end of the line so far
        li    s0, 0                    # s0: 1 for -a
        li    t0, 1
        beq   a0, t0, 2f
        li    t0, 2
        bne   a0, t0, un_usage
        lw    t0, 3(a1)                # the one argument must be -a
        la    t1, un_all
1:      lt    t2, 0(t0)
        lt    t3, 0(t1)
        bne   t2, t3, un_usage
        addi  t0, t0, 1
        addi  t1, t1, 1
        bnez  t2, 1b
        li    s0, 1
2:      la    a2, un_name
        call  un_str
        beqz  s0, 3f
        li    a0, SYS_INFO
        la    a1, un_info
        sys
        li    t0, ' '
        st    t0, 0(s8)
        addi  s8, s8, 1
        la    a2, un_info + SI_RELEASE
        call  un_str
        la    a2, un_machine
        call  un_str
3:      li    t0, '\n'
        st    t0, 0(s8)
        addi  s8, s8, 1
        call  un_flush
        lw    a1, un_status
        li    a0, SYS_EXIT
        sys

un_usage:
        li    a0, SYS_WRITE
        li    a1, STDERR
        la    a2, un_use
        li    a3, UN_USE_LEN
        sys
        li    a0, SYS_EXIT
        li    a1, 2
        sys

# un_str: append the string at a2 to the line at s8, moving s8 past it.
# Clobbers t0.
un_str:
1:      lt    t0, 0(a2)
        beqz  t0, 2f
        st    t0, 0(s8)
        addi  a2, a2, 1
        addi  s8, s8, 1
        j     1b
2:      ret

# un_num: append a0 in decimal to the line at s8, right-aligned in a1
# columns (none if a1 is 0), moving s8 past it. Clobbers t0..t3.
un_num:
        la    t2, un_digits_end
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
1:      la    t3, un_digits_end
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

# un_flush: write the line from un_line to s8 to standard output and
# start a new one; un_status becomes 1 if that fails. Clobbers a0..a5, t0.
un_flush:
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, un_line
        sub   a3, s8, a2
        la    s8, un_line
        blez  a3, 1f
        sys
        bgez  a0, 1f
        li    t0, 1
        sw    t0, un_status
1:      ret

        .align 1
un_status:  .word 0                    # the exit code: 1 once output failed
un_digits: .zero 12
un_digits_end:
un_line:   .zero 243
        .align 1
un_info:    .words SYSINFO / 3
un_name:    .string "trylobite"
un_machine: .string " detrytus"
un_all:     .string "-a"
un_use:     .string "usage: uname [-a]\n"
        .equ  UN_USE_LEN, 18
        .nocompress
