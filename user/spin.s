# Program 6 of shell.s: loop forever without a system call, a runaway to
# try Ctrl-C on. Only the timer takes the hart away from it.

        .compress
        .section prog6, P_PROG6 * PAGE, V_USER

spin:   j     spin
        .nocompress
