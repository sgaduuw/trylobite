# Program 4 of shell.s: exit with code 3 at once, so the shell has
# something to report.

        .section prog4, P_PROG4 * PAGE, V_USER

fail:   li    a0, SYS_EXIT
        li    a1, 3
        sys
