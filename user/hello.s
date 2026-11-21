# Program 3 of shell.s: say hello, and exit with 0.

        .compress
        .section prog3, P_PROG3 * PAGE, V_USER
        .gp   USER_GP                  # set by spawn

hello:  la    a1, hello_msg
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_EXIT
        li    a1, 0
        sys

hello_msg: .string "hello from a balanced-ternary machine\n"
        .nocompress
