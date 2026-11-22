# head [-n N] [FILE]...: say the first N lines (10 unless given) of each
# file, or of standard input when none is named, on standard output, as
# Unix's head does: with two files or more, each starts with a line
# "==> NAME <==", and a blank line comes between them. Exit with 0, or
# with 1 if a file cannot be opened (said on standard error), N is not
# a number, or output fails. A filter too: ls bin | head -n 3.

        .include "../include/layout.s"
        .compress
        .section head, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  HD_MAX, 243              # trytes read at a time
        .equ  HD_LINES, 10             # lines said when -n is not given

head:   addi  s7, a0, -1               # s7: arguments left
        addi  s8, a1, 3                # s8: the next one's argv word
        li    t0, HD_LINES
        sw    t0, hd_lines
        blez  s7, 2f
        lw    t0, 0(s8)                # -n N?
        lt    t1, 0(t0)
        li    t2, '-'
        bne   t1, t2, 2f
        lt    t1, 1(t0)
        li    t2, 'n'
        bne   t1, t2, hd_usage
        lt    t1, 2(t0)
        bnez  t1, hd_usage
        li    t0, 2
        blt   s7, t0, hd_usage
        lw    t0, 3(s8)                # N: decimal digits, at least one
        li    t3, 0
        lt    t1, 0(t0)
        beqz  t1, hd_usage
1:      lt    t1, 0(t0)
        beqz  t1, 0f
        addi  t1, t1, -'0'
        bltz  t1, hd_usage
        li    t2, 9
        bgt   t1, t2, hd_usage
        li    t2, 10
        mul   t3, t3, t2
        add   t3, t3, t1
        addi  t0, t0, 1
        j     1b
0:      sw    t3, hd_lines
        addi  s7, s7, -2
        addi  s8, s8, 6
2:      sw    s7, hd_files
        bgtz  s7, 3f
        li    s5, STDIN                # none: standard input
        call  hd_copy
        j     hd_end

3:      li    a0, SYS_LOOKUP           # the file server, to open them
        la    a1, hd_fsname
        li    a2, LOOKUP_NOW
        sys
        li    s1, HD_NOFS              # s1: it, or HD_NOFS
        bltz  a0, 4f
        li    t0, FS_PROTOCOL
        bne   a1, t0, 4f
        mv    s1, a0
4:      li    a0, SYS_CALL
        mv    a1, s1
        li    a2, FS_OPEN
        lw    a3, 0(s8)
        li    a4, O_RDONLY
        sys
        bgez  a0, 5f
        la    a2, hd_me                # head: NAME: cannot open
        call  hd_err
        lw    a2, 0(s8)
        call  hd_err
        la    a2, hd_noopen
        call  hd_err
        li    t0, 1
        sw    t0, hd_status
        j     7f
5:      mv    s5, a0                   # s5: its descriptor
        lw    t0, hd_files
        li    t1, 2
        blt   t0, t1, 6f
        lw    t0, hd_said              # ==> NAME <==, after a blank line
        beqz  t0, 0f                   # if one came before
        la    a2, hd_newline
        li    a3, 1
        call  hd_out
0:      li    t0, 1
        sw    t0, hd_said
        la    a2, hd_open
        li    a3, 4
        call  hd_out
        lw    a2, 0(s8)
        call  hd_len
        call  hd_out
        la    a2, hd_close
        li    a3, 5
        call  hd_out
6:      call  hd_copy
        li    a0, SYS_CLOSE
        mv    a1, s5
        sys
7:      addi  s8, s8, 3
        addi  s7, s7, -1
        bgtz  s7, 4b
hd_end: lw    a1, hd_status
        li    a0, SYS_EXIT
        sys

hd_usage:
        la    a2, hd_use
        call  hd_err
        li    a1, 1
        li    a0, SYS_EXIT
        sys

# hd_copy: copy what descriptor s5 reads to standard output, up to the
# end of its hd_lines'th line or its end. Clobbers s0, s2, a0..a5 and
# t0..t3.
hd_copy:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        lw    s0, hd_lines             # s0: lines still to say
        blez  s0, 9f
1:      li    a0, SYS_READ
        mv    a1, s5
        la    a2, hd_buf
        li    a3, HD_MAX
        sys
        blez  a0, 9f                   # the end, or no input
        mv    s2, a0                   # s2: how many
        la    t0, hd_buf
        add   t1, t0, s2
2:      lt    t2, 0(t0)
        addi  t0, t0, 1
        li    t3, '\n'
        bne   t2, t3, 3f
        addi  s0, s0, -1
        beqz  s0, 4f                   # the last line ends here
3:      blt   t0, t1, 2b
4:      la    a2, hd_buf
        sub   a3, t0, a2
        call  hd_out
        bgtz  s0, 1b
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# hd_out: write a3 trytes from a2 to standard output, and set hd_status
# if that fails. Clobbers a0..a5, t0.
hd_out: li    a0, SYS_WRITE
        li    a1, STDOUT
        sys
        bgez  a0, 1f
        li    t0, 1
        sw    t0, hd_status
1:      ret

# hd_err: write the string at a2 to standard error. Clobbers a0..a5, t0.
hd_err: addi  sp, sp, -3
        sw    ra, 0(sp)
        call  hd_len
        li    a0, SYS_WRITE
        li    a1, STDERR
        sys
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# hd_len: a3 = the length of the string at a2. Clobbers t0.
hd_len: mv    a3, a2
1:      lt    t0, 0(a3)
        beqz  t0, 2f
        addi  a3, a3, 1
        j     1b
2:      sub   a3, a3, a2
        ret

        .equ  HD_NOFS, -1              # no file server: no process has the
                                       # number, so a call is E_NOPROC
        .align 1
hd_lines:   .word HD_LINES             # lines to say of each
hd_files:   .word 0                    # files named
hd_said:    .word 0                    # 1 once a file has been said
hd_status:  .word 0                    # the exit code: 1 once anything failed
hd_fsname:  .string "fs"
hd_me:      .string "head: "
hd_noopen:  .string ": cannot open\n"
hd_use:     .string "usage: head [-n N] [FILE]...\n"
hd_open:    .string "==> "
hd_close:   .string " <==\n"
hd_newline: .string "\n"
hd_buf:     .zero HD_MAX
        .nocompress
