# touch FILE...: make each FILE that is not there yet, empty, as Unix's
# touch does; one that is there is left as it is, since files have no
# times to bring up to date. Exit with 0, or with 1 if one cannot be
# made (said on standard error).

        .include "../include/layout.s"
        .compress
        .section touch, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

touch:  addi  s7, a0, -1               # s7: files left
        addi  s8, a1, 3                # s8: the next one's argv word
        li    s2, 0                    # s2: the exit code
        bgtz  s7, 1f
        la    a2, tc_usage
        call  tc_err
        li    s2, 1
        j     tc_end
1:      li    a0, SYS_LOOKUP           # the file server
        la    a1, tc_fsname
        li    a2, LOOKUP_NOW
        sys
        li    s1, TC_NOFS              # s1: it, or TC_NOFS
        bltz  a0, 2f
        li    t0, FS_PROTOCOL
        bne   a1, t0, 2f
        mv    s1, a0
2:      li    a0, SYS_CALL             # open it for reading, made if need be,
        mv    a1, s1                   # which a directory allows too
        li    a2, FS_OPEN
        lw    a3, 0(s8)
        li    a4, O_RDONLY + O_CREAT
        sys
        bltz  a0, 3f
        mv    a1, a0
        li    a0, SYS_CLOSE
        sys
        j     4f
3:      la    a2, tc_me                # touch: NAME: cannot make
        call  tc_err
        lw    a2, 0(s8)
        call  tc_err
        la    a2, tc_nomake
        call  tc_err
        li    s2, 1
4:      addi  s8, s8, 3
        addi  s7, s7, -1
        bgtz  s7, 2b
tc_end: mv    a1, s2
        li    a0, SYS_EXIT
        sys

# tc_err: write the string at a2 to standard error. Clobbers a0..a5, t0.
tc_err: mv    a3, a2
1:      lt    t0, 0(a3)
        beqz  t0, 2f
        addi  a3, a3, 1
        j     1b
2:      sub   a3, a3, a2
        li    a0, SYS_WRITE
        li    a1, STDERR
        sys
        ret

        .equ  TC_NOFS, -1              # no file server: no process has the
                                       # number, so a call is E_NOPROC
tc_fsname:  .string "fs"
tc_me:      .string "touch: "
tc_nomake:  .string ": cannot make\n"
tc_usage:   .string "usage: touch FILE...\n"
        .nocompress
