# cp FROM TO, cp FROM... DIR: copy file FROM to TO, made or emptied
# first, or each FROM into directory DIR under its own last name, as
# Unix's cp does. Directories are not copied, nor a file onto itself.
# Exit with 0, or with 1 if anything fails (said on standard error).

        .include "../include/layout.s"
        .compress
        .section cp, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  CP_MAX, 243              # trytes copied at a time

cp:     addi  s7, a0, -2               # s7: files to copy
        addi  s8, a1, 3                # s8: the next one's argv word
        blez  s7, cp_usage
        li    t0, 3                    # the last word names where to
        mul   t0, s7, t0
        add   t0, s8, t0
        lw    t0, 0(t0)
        sw    t0, cp_to
        li    a0, SYS_LOOKUP           # the file server
        la    a1, cp_fsname
        li    a2, LOOKUP_NOW
        sys
        li    s1, CP_NOFS              # s1: it, or CP_NOFS
        bltz  a0, 1f
        li    t0, FS_PROTOCOL
        bne   a1, t0, 1f
        mv    s1, a0
1:      lw    a3, cp_to                # into a directory?
        call  cp_stat
        bltz  a0, 2f
        lw    t0, cp_st + ST_TYPE
        li    t1, T_DIR
        bne   t0, t1, 2f
        li    t0, 1
        sw    t0, cp_into
        j     3f
2:      li    t0, 1                    # not one: only one file may be copied
        beq   s7, t0, 3f
        lw    a2, cp_to
        la    a3, cp_notdir
        call  cp_fail
        j     cp_end

3:      lw    a2, cp_to                # to where?
        lw    t0, cp_into
        beqz  t0, 4f
        lw    a3, 0(s8)
        call  cp_join
        bltz  a0, 6f
        la    a2, cp_path
4:      sw    a2, cp_dest
        call  cp_one
6:      addi  s8, s8, 3
        addi  s7, s7, -1
        bgtz  s7, 3b
cp_end: lw    a1, cp_status
        li    a0, SYS_EXIT
        sys

cp_usage:
        la    a2, cp_use
        call  cp_err
        li    a1, 1
        li    a0, SYS_EXIT
        sys

# cp_one: copy the file 0(s8) names to the one cp_dest names, saying
# why if it cannot. Clobbers s0, s2..s6, a0..a5 and t0..t2.
cp_one: addi  sp, sp, -3
        sw    ra, 0(sp)
        lw    a3, 0(s8)                # what it is
        call  cp_stat
        bltz  a0, 7f
        lw    t0, cp_st + ST_TYPE
        li    t1, T_DIR
        beq   t0, t1, 8f
        lw    s6, cp_st + ST_INO       # s6: its inode
        lw    a3, cp_dest              # and not itself
        call  cp_stat
        bltz  a0, 1f
        lw    t0, cp_st + ST_INO
        beq   t0, s6, 9f
1:      li    a0, SYS_CALL
        mv    a1, s1
        li    a2, FS_OPEN
        lw    a3, 0(s8)
        li    a4, O_RDONLY
        sys
        bltz  a0, 7f
        mv    s3, a0                   # s3: reading it
        li    a0, SYS_CALL
        mv    a1, s1
        li    a2, FS_OPEN
        lw    a3, cp_dest
        li    a4, O_WRONLY + O_CREAT + O_TRUNC
        sys
        bltz  a0, 5f
        mv    s4, a0                   # s4: writing the copy
2:      li    a0, SYS_READ
        mv    a1, s3
        la    a2, cp_buf
        li    a3, CP_MAX
        sys
        beqz  a0, 4f                   # the end
        bltz  a0, 6f
        la    s5, cp_buf               # s5: what is still to write,
        add   s2, s5, a0               # up to s2
3:      li    a0, SYS_WRITE            # a write stops at a block's end
        mv    a1, s4
        mv    a2, s5
        sub   a3, s2, s5
        sys
        blez  a0, 6f
        add   s5, s5, a0
        blt   s5, s2, 3b
        j     2b
6:      lw    a2, cp_dest              # cp: TO: cannot write
        la    a3, cp_nowrite
        call  cp_fail
4:      li    a0, SYS_CLOSE
        mv    a1, s4
        sys
        j     0f
5:      lw    a2, cp_dest              # cp: TO: cannot make
        la    a3, cp_nomake
        call  cp_fail
0:      li    a0, SYS_CLOSE
        mv    a1, s3
        sys
        j     10f
7:      lw    a2, 0(s8)                # cp: FROM: cannot open
        la    a3, cp_noopen
        call  cp_fail
        j     10f
8:      lw    a2, 0(s8)                # cp: FROM: is a directory
        la    a3, cp_isdir
        call  cp_fail
        j     10f
9:      lw    a2, 0(s8)                # cp: FROM: is TO already
        la    a3, cp_same
        call  cp_fail
10:     lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# cp_stat: stat the path at a3 into cp_st: a0 = 0, or why not. Clobbers
# a1..a5.
cp_stat:
        li    a0, SYS_CALL
        mv    a1, s1
        li    a2, FS_STAT
        la    a4, cp_st
        sys
        ret

# cp_join: put the directory path at a2, a slash and the last name of
# the path at a3 in cp_path: a0 = 0, or E_NAMETOOLONG, said, when that
# is longer than PATH_MAX. Clobbers a1..a5, t0..t2.
cp_join:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    t0, cp_path              # t0: where the next tryte goes
        la    t2, cp_path + PATH_MAX   # t2: where none may go
1:      lt    t1, 0(a2)
        beqz  t1, 2f
        bge   t0, t2, 8f
        st    t1, 0(t0)
        addi  t0, t0, 1
        addi  a2, a2, 1
        j     1b
2:      bge   t0, t2, 8f
        li    t1, '/'
        st    t1, 0(t0)
        addi  t0, t0, 1
        mv    a2, a3                   # the last name: past the last slash
        call  cp_len                   # that has something after it
        add   a4, a2, a3               # a4: its end
3:      ble   a4, a2, 4f
        lt    t1, -1(a4)
        li    a5, '/'
        bne   t1, a5, 4f
        addi  a4, a4, -1
        j     3b
4:      mv    a5, a4                   # a5: its start
5:      ble   a5, a2, 6f
        lt    t1, -1(a5)
        li    a1, '/'
        beq   t1, a1, 6f
        addi  a5, a5, -1
        j     5b
6:      bge   a5, a4, 7f
        bge   t0, t2, 8f
        lt    t1, 0(a5)
        st    t1, 0(t0)
        addi  t0, t0, 1
        addi  a5, a5, 1
        j     6b
7:      st    zero, 0(t0)
        li    a0, 0
        j     9f
8:      mv    a2, a3                   # cp: FROM: name too long
        la    a3, cp_toolong
        call  cp_fail
        li    a0, E_NAMETOOLONG
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# cp_fail: say "cp: ", the string at a2 and the one at a3 on standard
# error, and make the exit code 1. Clobbers a0..a5, t0.
cp_fail:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a3, 3(sp)
        li    t0, 1
        sw    t0, cp_status
        sw    a2, cp_what
        la    a2, cp_me
        call  cp_err
        lw    a2, cp_what
        call  cp_err
        lw    a2, 3(sp)
        call  cp_err
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# cp_err: write the string at a2 to standard error. Clobbers a0..a5, t0.
cp_err: addi  sp, sp, -3
        sw    ra, 0(sp)
        call  cp_len
        li    a0, SYS_WRITE
        li    a1, STDERR
        sys
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# cp_len: a3 = the length of the string at a2. Clobbers t1.
cp_len: mv    a3, a2
1:      lt    t1, 0(a3)
        beqz  t1, 2f
        addi  a3, a3, 1
        j     1b
2:      sub   a3, a3, a2
        ret

        .equ  CP_NOFS, -1              # no file server: no process has the
                                       # number, so a call is E_NOPROC
        .align 1
cp_to:      .word 0                    # the last argument
cp_into:    .word 0                    # 1 if that is a directory
cp_dest:    .word 0                    # where this file goes
cp_what:    .word 0
cp_status:  .word 0                    # the exit code: 1 once anything failed
cp_st:      .words STAT / 3
cp_fsname:  .string "fs"
cp_me:      .string "cp: "
cp_noopen:  .string ": cannot open\n"
cp_nomake:  .string ": cannot make\n"
cp_nowrite: .string ": cannot write\n"
cp_isdir:   .string ": is a directory\n"
cp_same:    .string ": is the same file\n"
cp_notdir:  .string ": not a directory\n"
cp_toolong: .string ": name too long\n"
cp_use:     .string "usage: cp FROM TO, or cp FROM... DIR\n"
cp_buf:     .zero CP_MAX
cp_path:    .zero PATH_MAX + 1
        .nocompress
