# hello: say hello through the console server, and exit with 0; with no
# console server, exit with 1. A program for the disk, like everything
# in bin/: assembled on its own to run at V_USER, and put on a disk with
# tools/fs.py (docs/filesystem.md, Program files).

        .include "../include/layout.s"
        .compress
        .section hello, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

hello:  li    a0, SYS_LOOKUP
        la    a1, hello_con
        li    a2, LOOKUP_NOW           # the shell started it long ago
        sys
        bltz  a0, 1f
        li    t0, CONSOLE_PROTOCOL
        bne   a1, t0, 1f
        mv    a1, a0
        li    a0, SYS_CALL
        li    a2, CN_WRITE
        la    a3, hello_msg
        li    a4, hello_end - hello_msg - 1   # not its 0
        sys
        bltz  a0, 1f
        li    a1, 0
        j     2f
1:      li    a1, 1
2:      li    a0, SYS_EXIT
        sys

hello_con: .string "console"
hello_msg: .string "hello from a balanced-ternary machine\n"
hello_end:
        .nocompress
