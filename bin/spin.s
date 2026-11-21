# spin: loop forever without a system call, a runaway to try Ctrl-C on.
# Only the timer takes the hart away from it.

        .include "../include/layout.s"
        .compress
        .section spin, V_USER, V_USER

spin:   j     spin
        .nocompress
