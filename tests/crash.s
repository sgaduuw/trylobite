# crash: fault at once, for init's tests (tests/test_init.py): a program
# /etc/init names that faults is started again.

        .include "../include/layout.s"
        .compress
        .section crash, V_USER, V_USER

crash:  lw    t0, 0(zero)              # nothing is there
        .nocompress
