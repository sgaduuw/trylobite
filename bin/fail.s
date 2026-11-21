# fail: exit with code 3 at once, so the shell has something to report.

        .include "../include/layout.s"
        .compress
        .section fail, V_USER, V_USER

fail:   li    a0, SYS_EXIT
        li    a1, 3
        sys
        .nocompress
