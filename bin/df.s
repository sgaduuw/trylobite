# df: say how full the disk is, on standard output, as Unix's df does:
# its blocks (a page each) used and free, the share used, and its inodes
# (files and directories) and how many are free. There is one disk, the
# file server's, holding /. Exit with 0, with 1 if output fails, or with
# 2 if there is no filesystem (said on standard error).

        .include "../include/layout.s"
        .compress
        .section df, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  DF_COL, 9                # columns for each number

df:     la    s8, df_line              # s8: the end of the line so far
        li    a0, SYS_LOOKUP
        la    a1, df_fsname
        li    a2, LOOKUP_NOW
        sys
        bltz  a0, df_nofs
        li    t0, FS_PROTOCOL
        bne   a1, t0, df_nofs
        mv    a1, a0
        li    a0, SYS_CALL
        li    a2, FS_STATFS
        la    a3, df_sf
        sys
        bltz  a0, df_nofs
        la    a2, df_head
        call  df_str
        call  df_flush
        la    a2, df_disk
        call  df_str
        lw    s0, df_sf + SF_BLOCKS
        lw    s1, df_sf + SF_BFREE
        sub   s2, s0, s1               # s2: blocks used
        mv    a0, s0
        li    a1, DF_COL
        call  df_num
        mv    a0, s2
        li    a1, DF_COL
        call  df_num
        mv    a0, s1
        li    a1, DF_COL
        call  df_num
        li    a0, 0                    # the share used, rounded up as
        blez  s0, 1f                   # Unix's df does
        li    t0, 100
        mul   a0, s2, t0
        add   a0, a0, s0
        addi  a0, a0, -1
        div   a0, a0, s0
1:      li    a1, 5
        call  df_num
        li    t0, '%'
        st    t0, 0(s8)
        addi  s8, s8, 1
        lw    a0, df_sf + SF_INODES
        li    a1, DF_COL
        call  df_num
        lw    a0, df_sf + SF_IFREE
        li    a1, DF_COL
        call  df_num
        la    a2, df_root
        call  df_str
        call  df_flush
        lw    a1, df_status
        li    a0, SYS_EXIT
        sys

df_nofs:
        li    a0, SYS_WRITE
        li    a1, STDERR
        la    a2, df_nofsmsg
        li    a3, DF_NOFS_LEN
        sys
        li    a0, SYS_EXIT
        li    a1, 2
        sys

# df_str: append the string at a2 to the line at s8, moving s8 past it.
# Clobbers t0.
df_str:
1:      lt    t0, 0(a2)
        beqz  t0, 2f
        st    t0, 0(s8)
        addi  a2, a2, 1
        addi  s8, s8, 1
        j     1b
2:      ret

# df_num: append a0 in decimal to the line at s8, right-aligned in a1
# columns (none if a1 is 0), moving s8 past it. Clobbers t0..t3.
df_num:
        la    t2, df_digits_end
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
1:      la    t3, df_digits_end
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

# df_flush: write the line from df_line to s8 to standard output and
# start a new one; df_status becomes 1 if that fails. Clobbers a0..a5, t0.
df_flush:
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, df_line
        sub   a3, s8, a2
        la    s8, df_line
        blez  a3, 1f
        sys
        bgez  a0, 1f
        li    t0, 1
        sw    t0, df_status
1:      ret

        .align 1
df_status:  .word 0                    # the exit code: 1 once output failed
df_digits: .zero 12
df_digits_end:
df_line:   .zero 243
df_sf:      .words STATFS / 3
df_fsname:  .string "fs"
df_head:    .string "Filesystem    Blocks     Used     Free  Use%   Inodes    IFree  Mounted on\n"
df_disk:    .string "disk0      "
df_root:    .string "  /\n"
df_nofsmsg: .string "df: no filesystem\n"
        .equ  DF_NOFS_LEN, 18
        .nocompress
