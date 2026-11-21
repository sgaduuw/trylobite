# hello: say hello, and exit with 0. A program for the disk, like
# everything in bin/: assembled on its own to run at V_USER, and put on a
# disk with tools/fs.py (docs/filesystem.md, Program files).

        .include "../include/layout.s"
        .compress
        .section hello, V_USER, V_USER
        .gp   USER_GP                  # set by spawnw

hello:  la    a1, hello_msg
        li    a0, SYS_PUTS
        sys
        li    a0, SYS_EXIT
        li    a1, 0
        sys

hello_msg: .string "hello from a balanced-ternary machine\n"
        .nocompress
