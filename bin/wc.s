# wc [FILE]...: count the lines, words and code points of each file, or
# of standard input when none is named, and say them on standard output,
# as Unix's wc does: a line per file, ending with its name, and a total
# when there are two or more. Exit with 0, or with 1 if a file cannot be
# opened (said on standard error) or output fails. A filter too, for the
# end of a pipe: ls | wc.

        .include "../include/layout.s"
        .compress
        .section wc, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  WC_MAX, 243              # trytes read at a time

wc:     addi  s7, a0, -1               # s7: files left to count
        addi  s8, a1, 3                # s8: the next one's argv word
        sw    s7, wc_files
        bgtz  s7, 1f
        li    s5, STDIN                # none: standard input, with no name
        call  wc_count
        li    a2, 0
        call  wc_say
        j     wc_end

1:      li    a0, SYS_LOOKUP           # the file server, to open them
        la    a1, wc_fsname
        li    a2, LOOKUP_NOW
        sys
        bltz  a0, 0f
        li    t0, FS_PROTOCOL
        bne   a1, t0, 0f
        sw    a0, wc_fs
        j     2f
0:      li    t0, WC_NOFS              # every open then fails, and says so
        sw    t0, wc_fs
2:      li    a0, SYS_CALL
        lw    a1, wc_fs
        li    a2, FS_OPEN
        lw    a3, 0(s8)
        li    a4, O_RDONLY
        sys
        bgez  a0, 3f
        la    a2, wc_me                # wc: NAME: cannot open
        call  wc_err
        lw    a2, 0(s8)
        call  wc_err
        la    a2, wc_noopen
        call  wc_err
        li    t0, 1
        sw    t0, wc_status
        j     4f
3:      mv    s5, a0                   # s5: its descriptor
        call  wc_count
        li    a0, SYS_CLOSE
        mv    a1, s5
        sys
        lw    t0, wc_tl                # into the totals
        add   t0, t0, s0
        sw    t0, wc_tl
        lw    t0, wc_tw
        add   t0, t0, s1
        sw    t0, wc_tw
        lw    t0, wc_tc
        add   t0, t0, s2
        sw    t0, wc_tc
        lw    a2, 0(s8)
        call  wc_say
4:      addi  s8, s8, 3
        addi  s7, s7, -1
        bgtz  s7, 2b
        lw    t0, wc_files
        li    t1, 2
        blt   t0, t1, wc_end
        lw    s0, wc_tl
        lw    s1, wc_tw
        lw    s2, wc_tc
        la    a2, wc_total
        call  wc_say
wc_end: lw    a1, wc_status
        li    a0, SYS_EXIT
        sys

# wc_count: count what descriptor s5 reads until its end: s0 lines, s1
# words, s2 code points. Clobbers s3, a0..a5 and t0..t3.
wc_count:
        li    s0, 0
        li    s1, 0
        li    s2, 0
        li    s3, 0                    # s3: 1 inside a word
1:      li    a0, SYS_READ
        mv    a1, s5
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
5:      ret

# wc_say: say s0, s1 and s2, and the name at a2 unless a2 is 0, on a line
# of standard output; set wc_status if that fails. Clobbers s4, s6,
# a0..a5 and t0..t3.
wc_say: addi  sp, sp, -3
        sw    ra, 0(sp)
        mv    s6, a2                   # s6: the name, or 0
        la    s4, wc_out               # s4: where the next number goes
        mv    a0, s0
        call  wc_num
        mv    a0, s1
        call  wc_num
        mv    a0, s2
        call  wc_num
        bnez  s6, 1f
        li    t0, '\n'                 # no name: the last space becomes
        st    t0, -1(s4)               # the newline
1:      la    a2, wc_out
        sub   a3, s4, a2
        call  wc_out1
        beqz  s6, 2f
        mv    a2, s6
        call  wc_len
        call  wc_out1
        la    a2, wc_newline
        li    a3, 1
        call  wc_out1
2:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# wc_out1: write a3 trytes from a2 to standard output, and set wc_status
# if that fails. Clobbers a0..a5, t0.
wc_out1:
        li    a0, SYS_WRITE
        li    a1, STDOUT
        sys
        bgez  a0, 1f
        li    t0, 1
        sw    t0, wc_status
1:      ret

# wc_err: write the string at a2 to standard error. Clobbers a0..a5, t0.
wc_err: addi  sp, sp, -3
        sw    ra, 0(sp)
        call  wc_len
        li    a0, SYS_WRITE
        li    a1, STDERR
        sys
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# wc_len: a3 = the length of the string at a2. Clobbers t0.
wc_len: mv    a3, a2
1:      lt    t0, 0(a3)
        beqz  t0, 2f
        addi  a3, a3, 1
        j     1b
2:      sub   a3, a3, a2
        ret

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

        .equ  WC_NOFS, -1              # wc_fs with no file server: no process
                                       # has the number, so a call is E_NOPROC
        .align 1
wc_fs:      .word WC_NOFS
wc_files:   .word 0                    # files named
wc_status:  .word 0                    # the exit code: 1 once anything failed
wc_tl:      .word 0                    # the totals: lines,
wc_tw:      .word 0                    # words
wc_tc:      .word 0                    # and code points
wc_fsname:  .string "fs"
wc_me:      .string "wc: "
wc_noopen:  .string ": cannot open\n"
wc_total:   .string "total"
wc_newline: .string "\n"
wc_buf:     .zero WC_MAX
wc_digits:  .zero 12
wc_digits_end:
wc_out:     .zero 40
        .nocompress
