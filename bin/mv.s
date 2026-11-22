# mv FROM TO, mv FROM... DIR: give file or directory FROM the name TO,
# replacing a file of that name, or move each FROM into directory DIR
# under its own last name, as Unix's mv does. A rename in the file
# server (FS_RENAME), so nothing is copied. Exit with 0, or with 1 if
# anything fails (said on standard error).

        .include "../include/layout.s"
        .compress
        .section mv, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

mv:     addi  s7, a0, -2               # s7: names to move
        addi  s8, a1, 3                # s8: the next one's argv word
        blez  s7, mv_usage
        li    t0, 3                    # the last word names where to
        mul   t0, s7, t0
        add   t0, s8, t0
        lw    t0, 0(t0)
        sw    t0, mv_to
        li    a0, SYS_LOOKUP           # the file server
        la    a1, mv_fsname
        li    a2, LOOKUP_NOW
        sys
        li    s1, MV_NOFS              # s1: it, or MV_NOFS
        bltz  a0, 1f
        li    t0, FS_PROTOCOL
        bne   a1, t0, 1f
        mv    s1, a0
1:      li    a0, SYS_CALL             # into a directory?
        mv    a1, s1
        li    a2, FS_STAT
        lw    a3, mv_to
        la    a4, mv_st
        sys
        bltz  a0, 2f
        lw    t0, mv_st + ST_TYPE
        li    t1, T_DIR
        bne   t0, t1, 2f
        li    t0, 1
        sw    t0, mv_into
        j     3f
2:      li    t0, 1                    # not one: only one may be moved
        beq   s7, t0, 3f
        lw    a2, mv_to
        la    a3, mv_notdir
        call  mv_fail
        j     mv_end

3:      lw    a2, mv_to                # to where?
        lw    t0, mv_into
        beqz  t0, 4f
        lw    a3, 0(s8)
        call  mv_join
        bltz  a0, 6f
        la    a2, mv_path
4:      mv    a4, a2
        li    a0, SYS_CALL
        mv    a1, s1
        li    a2, FS_RENAME
        lw    a3, 0(s8)
        sys
        bgez  a0, 6f
        la    t1, mv_whys              # mv: FROM: why
1:      lw    t0, 0(t1)
        beqz  t0, 5f                   # none listed: cannot move
        beq   t0, a0, 5f
        addi  t1, t1, 6
        j     1b
5:      lw    a3, 3(t1)
        lw    a2, 0(s8)
        call  mv_fail
6:      addi  s8, s8, 3
        addi  s7, s7, -1
        bgtz  s7, 3b
mv_end: lw    a1, mv_status
        li    a0, SYS_EXIT
        sys

mv_usage:
        la    a2, mv_use
        call  mv_err
        li    a1, 1
        li    a0, SYS_EXIT
        sys

# mv_join: put the directory path at a2, a slash and the last name of
# the path at a3 in mv_path: a0 = 0, or E_NAMETOOLONG, said, when that
# is longer than PATH_MAX. Clobbers a1..a5, t0..t2.
mv_join:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    t0, mv_path              # t0: where the next tryte goes
        la    t2, mv_path + PATH_MAX   # t2: where none may go
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
        call  mv_len                   # that has something after it
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
8:      mv    a2, a3                   # mv: FROM: name too long
        la    a3, mv_toolong
        call  mv_fail
        li    a0, E_NAMETOOLONG
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# mv_fail: say "mv: ", the string at a2 and the one at a3 on standard
# error, and make the exit code 1. Clobbers a0..a5, t0, t1.
mv_fail:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a3, 3(sp)
        li    t0, 1
        sw    t0, mv_status
        sw    a2, mv_what
        la    a2, mv_me
        call  mv_err
        lw    a2, mv_what
        call  mv_err
        lw    a2, 3(sp)
        call  mv_err
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# mv_err: write the string at a2 to standard error. Clobbers a0..a5, t1.
mv_err: addi  sp, sp, -3
        sw    ra, 0(sp)
        call  mv_len
        li    a0, SYS_WRITE
        li    a1, STDERR
        sys
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# mv_len: a3 = the length of the string at a2. Clobbers t1.
mv_len: mv    a3, a2
1:      lt    t1, 0(a3)
        beqz  t1, 2f
        addi  a3, a3, 1
        j     1b
2:      sub   a3, a3, a2
        ret

        .equ  MV_NOFS, -1              # no file server: no process has the
                                       # number, so a call is E_NOPROC
        .align 1
mv_to:      .word 0                    # the last argument
mv_into:    .word 0                    # 1 if that is a directory
mv_what:    .word 0
mv_status:  .word 0                    # the exit code: 1 once anything failed
mv_st:      .words STAT / 3
mv_whys:    .word E_NOENT, mv_noent    # what rename's failures mean,
            .word E_NOTDIR, mv_noent
            .word E_BUSY, mv_busy
            .word E_ISDIR, mv_isdir
            .word E_EXIST, mv_exist
            .word E_INVAL, mv_inval
            .word E_NOSPC, mv_nospc
            .word 0, mv_cannot         # and any other
mv_fsname:  .string "fs"
mv_me:      .string "mv: "
mv_noent:   .string ": no such file or directory\n"
mv_busy:    .string ": in use\n"
mv_isdir:   .string ": would replace a directory\n"
mv_exist:   .string ": would replace what is there\n"
mv_inval:   .string ": cannot move there\n"
mv_nospc:   .string ": no room\n"
mv_cannot:  .string ": cannot move\n"
mv_notdir:  .string ": not a directory\n"
mv_toolong: .string ": name too long\n"
mv_use:     .string "usage: mv FROM TO, or mv FROM... DIR\n"
mv_path:    .zero PATH_MAX + 1
        .nocompress
