# Program 0, started by the kernel: start pong and ping, tell ping where
# pong is, and leave them to it.

        .compress
        .section prog0, P_PROG0 * PAGE, V_USER
        .gp   USER_GP                  # set by spawn

init:   la    a1, init_msg
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_SPAWN
        li    a1, 2                    # pong
        sys
        mv    s0, a0                   # s0: pong's process number
        li    a0, SYS_SPAWN
        li    a1, 1                    # ping
        sys
        mv    a1, a0                   # send ping the number of pong
        li    a0, SYS_SEND
        mv    a2, s0
        sys
        li    a0, SYS_EXIT
        li    a1, 0
        sys

init_msg: .string "init: starting pong and ping\n"
        .nocompress
