# hello: say hello on standard output, and exit with 0; with nothing
# there, exit with 1. A program for the disk, like everything
# in bin/: assembled on its own to run at V_USER, and put on a disk with
# tools/fs.py (docs/filesystem.md, Program files).

        .include "../include/layout.s"
        .compress
        .section hello, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

hello:  li    a0, SYS_WRITE
        li    a1, STDOUT
        la    a2, hello_msg
        li    a3, hello_end - hello_msg - 1   # not its 0
        sys
        bltz  a0, 1f
        li    a1, 0
        j     2f
1:      li    a1, 1
2:      li    a0, SYS_EXIT
        sys

hello_msg: .string "hello from a balanced-ternary machine\n"
hello_end:
        .nocompress
