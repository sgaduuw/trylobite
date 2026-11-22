# Program 3 of shell.s: the demo's init, as a program the shell runs.
# Start pong and ping, tell ping where pong is, and wait for both, so
# that the shell's prompt comes back only once they are done.

        .compress
        .section prog3, (P_PROG0 + 3) * PAGE, V_USER
        .gp   USER_GP                  # set by spawn

pingpong:
        la    a1, pingpong_msg
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_SPAWN
        li    a1, 2                    # pong
        sys
        mv    s0, a0                   # s0: pong's process number
        li    a0, SYS_SPAWN
        li    a1, 1                    # ping
        sys
        mv    s1, a0                   # s1: ping's
        li    a0, SYS_SEND             # send ping the number of pong
        mv    a1, s1
        mv    a2, s0
        sys
        li    a0, SYS_WAIT
        mv    a1, s1
        sys
        li    a0, SYS_WAIT
        mv    a1, s0
        sys
        li    a0, SYS_EXIT
        li    a1, 0
        sys

pingpong_msg: .string "pingpong: starting pong and ping\n"
        .nocompress
