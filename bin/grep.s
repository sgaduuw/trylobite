# grep [-v] TEXT [FILE]...: say each line of the files, or of standard
# input when none is named, that holds TEXT, or with -v each line that
# does not, on standard output, as Unix's grep does for a fixed string
# (grep -F): there are no patterns. With two files or more, each line
# starts with its file's name and a colon. A line longer than GR_LINE
# code points is taken a GR_LINE at a time. Exit with 0 if a line was
# said, 1 if none was, and 2 if a file cannot be opened (said on
# standard error) or output fails. A filter too: ls bin | grep e.

        .include "../include/layout.s"
        .compress
        .section grep, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  GR_MAX, 243              # trytes read at a time
        .equ  GR_LINE, 729             # the longest line looked at whole

grep:   addi  s7, a0, -1               # s7: arguments left
        addi  s8, a1, 3                # s8: the next one's argv word
        li    s3, 0                    # s3: 1 for -v
        blez  s7, gr_usage
        lw    t0, 0(s8)                # -v?
        lt    t1, 0(t0)
        li    t2, '-'
        bne   t1, t2, 1f
        lt    t1, 1(t0)
        li    t2, 'v'
        bne   t1, t2, gr_usage
        lt    t1, 2(t0)
        bnez  t1, gr_usage
        li    s3, 1
        addi  s7, s7, -1
        addi  s8, s8, 3
        blez  s7, gr_usage
1:      lw    s1, 0(s8)                # s1: the text, s2 its length
        mv    a2, s1
        call  gr_len
        mv    s2, a3
        addi  s7, s7, -1
        addi  s8, s8, 3
        li    s4, 0                    # s4: the name lines start with, or 0
        bgtz  s7, 2f
        li    s5, STDIN                # no file: standard input
        call  gr_file
        j     gr_end

2:      li    t0, 2
        blt   s7, t0, 0f
        li    s4, 1                    # names, set for each file below
0:      li    a0, SYS_LOOKUP           # the file server, to open them
        la    a1, gr_fsname
        li    a2, LOOKUP_NOW
        sys
        li    t1, GR_NOFS
        sw    t1, gr_fs
        bltz  a0, 3f
        li    t0, FS_PROTOCOL
        bne   a1, t0, 3f
        sw    a0, gr_fs
3:      li    a0, SYS_CALL
        lw    a1, gr_fs
        li    a2, FS_OPEN
        lw    a3, 0(s8)
        li    a4, O_RDONLY
        sys
        bgez  a0, 4f
        la    a2, gr_me                # grep: NAME: cannot open
        call  gr_err
        lw    a2, 0(s8)
        call  gr_err
        la    a2, gr_noopen
        call  gr_err
        li    t0, 1
        sw    t0, gr_failed
        j     5f
4:      mv    s5, a0                   # s5: its descriptor
        beqz  s4, 0f
        lw    s4, 0(s8)
0:      call  gr_file
        li    a0, SYS_CLOSE
        mv    a1, s5
        sys
5:      addi  s8, s8, 3
        addi  s7, s7, -1
        bgtz  s7, 3b
gr_end: li    a1, 2                    # 2: something failed,
        lw    t0, gr_failed
        bnez  t0, 1f
        li    a1, 0                    # 0: a line was said,
        lw    t0, gr_found
        bnez  t0, 1f
        li    a1, 1                    # 1: none was
1:      li    a0, SYS_EXIT
        sys

gr_usage:
        la    a2, gr_use
        call  gr_err
        li    a1, 2
        li    a0, SYS_EXIT
        sys

# gr_file: look at each line descriptor s5 reads, to its end, gathering
# them in gr_line. Clobbers s0, s6, a0..a5 and t0..t5.
gr_file:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    s0, 0                    # s0: trytes in gr_line
1:      li    a0, SYS_READ
        mv    a1, s5
        la    a2, gr_buf
        li    a3, GR_MAX
        sys
        blez  a0, 5f                   # the end, or no input
        la    s6, gr_buf               # s6: the next tryte read
        add   t0, s6, a0
        sw    t0, gr_bufend
2:      lw    t0, gr_bufend
        bge   s6, t0, 1b
        lt    t1, 0(s6)
        addi  s6, s6, 1
        li    t2, '\n'
        beq   t1, t2, 3f
        la    t0, gr_line
        add   t0, t0, s0
        st    t1, 0(t0)
        addi  s0, s0, 1
        li    t0, GR_LINE
        blt   s0, t0, 2b
3:      call  gr_look                  # a line, or as much as gr_line holds
        li    s0, 0
        j     2b
5:      beqz  s0, 6f                   # a last line with no newline
        call  gr_look
6:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# gr_look: say the s0 trytes in gr_line, as a line, if holding the text
# (s1, s2 long) is not what -v (s3) asks for. Clobbers a0..a5, t0..t5.
gr_look:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    t0, gr_line              # t0: where the text is tried
        add   t1, t0, s0
        sub   t1, t1, s2               # t1: the last place it fits
        li    t5, 1                    # t5: 1 if found
1:      bgt   t0, t1, 4f
        li    t2, 0                    # t2: trytes matched
2:      bge   t2, s2, 9f               # all of them
        add   t3, t0, t2
        lt    t3, 0(t3)
        add   t4, s1, t2
        lt    t4, 0(t4)
        bne   t3, t4, 3f
        addi  t2, t2, 1
        j     2b
3:      addi  t0, t0, 1
        j     1b
4:      li    t5, 0
9:      beq   t5, s3, 8f               # found and -v, or neither: not said
        li    t0, 1
        sw    t0, gr_found
        beqz  s4, 0f
        mv    a2, s4                   # NAME:
        call  gr_len
        call  gr_out
        la    a2, gr_colon
        li    a3, 1
        call  gr_out
0:      la    a2, gr_line
        mv    a3, s0
        call  gr_out
        la    a2, gr_newline
        li    a3, 1
        call  gr_out
8:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# gr_out: write a3 trytes from a2 to standard output, unless a3 is 0,
# and set gr_failed if that fails. Clobbers a0..a5, t0.
gr_out: beqz  a3, 1f
        li    a0, SYS_WRITE
        li    a1, STDOUT
        sys
        bgez  a0, 1f
        li    t0, 1
        sw    t0, gr_failed
1:      ret

# gr_err: write the string at a2 to standard error. Clobbers a0..a5, t0.
gr_err: addi  sp, sp, -3
        sw    ra, 0(sp)
        call  gr_len
        li    a0, SYS_WRITE
        li    a1, STDERR
        sys
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# gr_len: a3 = the length of the string at a2. Clobbers t0.
gr_len: mv    a3, a2
1:      lt    t0, 0(a3)
        beqz  t0, 2f
        addi  a3, a3, 1
        j     1b
2:      sub   a3, a3, a2
        ret

        .equ  GR_NOFS, -1              # no file server: no process has the
                                       # number, so a call is E_NOPROC
        .align 1
gr_fs:      .word GR_NOFS
gr_found:   .word 0                    # 1 once a line was said
gr_failed:  .word 0                    # 1 once anything failed
gr_bufend:  .word 0                    # just past what gr_buf holds
gr_fsname:  .string "fs"
gr_me:      .string "grep: "
gr_noopen:  .string ": cannot open\n"
gr_use:     .string "usage: grep [-v] TEXT [FILE]...\n"
gr_colon:   .string ":"
gr_newline: .string "\n"
gr_buf:     .zero GR_MAX
gr_line:    .zero GR_LINE
        .nocompress
