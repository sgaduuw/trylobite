# kill PID...: end each process named, as Unix's kill does with its
# default signal (there are no signals: a process just ends, and its
# parent's wait says it was killed). Any process but init, since there
# are no users to tell apart. A server killed is started again by init.
# Exit with 0, with 1 if a process could not be ended (said on standard
# error), or with 2 for no number or a bad one.

        .include "../include/layout.s"
        .compress
        .section kill, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  KL_NAN, -1               # kl_atoi: not a number, which no
                                       # process number is

kill:   addi  s0, a0, -1               # s0: numbers left
        addi  s1, a1, 3                # s1: the next one's argv word
        li    s2, 0                    # s2: the exit code
        blez  s0, kl_usage
1:      lw    a2, 0(s1)
        call  kl_atoi
        bltz  a0, kl_usage
        mv    a1, a0
        li    a0, SYS_KILL
        li    a2, KILL_ANY
        sys
        bgez  a0, 3f
        mv    s3, a0                   # s3: why not
        la    a2, kl_me                # kill: N: why
        call  kl_err
        lw    a2, 0(s1)
        call  kl_err
        la    a2, kl_noproc
        li    t0, E_PERM
        bne   s3, t0, 2f
        la    a2, kl_perm
2:      call  kl_err
        li    s2, 1
3:      addi  s1, s1, 3
        addi  s0, s0, -1
        bgtz  s0, 1b
        mv    a1, s2
        li    a0, SYS_EXIT
        sys

kl_usage:
        la    a2, kl_use
        call  kl_err
        li    a0, SYS_EXIT
        li    a1, 2
        sys

# kl_atoi: a0 = the number the string at a2 writes in decimal, or
# KL_NAN if it is not one (empty, a sign, anything but digits).
# Clobbers t0..t2.
kl_atoi:
        li    a0, 0
        lt    t0, 0(a2)
        beqz  t0, 2f                   # empty
1:      lt    t0, 0(a2)
        beqz  t0, 3f
        addi  t0, t0, -'0'
        bltz  t0, 2f
        li    t1, 9
        bgt   t0, t1, 2f
        li    t1, 10
        mul   a0, a0, t1
        add   a0, a0, t0
        addi  a2, a2, 1
        j     1b
2:      li    a0, KL_NAN
3:      ret

# kl_err: write the string at a2 to standard error. Clobbers a0..a5, t0.
kl_err:
        mv    a3, a2
1:      lt    t0, 0(a3)
        beqz  t0, 2f
        addi  a3, a3, 1
        j     1b
2:      sub   a3, a3, a2
        li    a0, SYS_WRITE
        li    a1, STDERR
        sys
        ret

kl_me:      .string "kill: "
kl_noproc:  .string ": no such process\n"
kl_perm:    .string ": not allowed\n"
kl_use:     .string "usage: kill PID...\n"
        .nocompress
