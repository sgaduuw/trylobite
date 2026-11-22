# dmesg: say the kernel's log on standard output: what it printed since
# boot, as far back as it keeps (LOG_SIZE code points), as Unix's dmesg
# prints the kernel's message buffer. The boot report is there, init's
# lines, and every process's ending. Exit with 0, or with 1 if output
# fails.

        .include "../include/layout.s"
        .compress
        .section dmesg, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

        .equ  DM_MAX, 243              # code points read at a time

dmesg:  li    s0, 0                    # s0: where the next read starts
1:      li    a0, SYS_LOG
        la    a1, dm_buf
        li    a2, DM_MAX
        mv    a3, s0
        sys
        blez  a0, 2f                   # all of it
        mv    s0, a1
        mv    a3, a0
        li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, dm_buf
        sys
        bgez  a0, 1b
        li    s1, 1                    # output failed
        j     3f
2:      li    s1, 0
3:      mv    a1, s1
        li    a0, SYS_EXIT
        sys

dm_buf: .zero DM_MAX
        .nocompress
