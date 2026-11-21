# Milestone 3: the kernel starts a shell, which runs the programs typed
# at it. Give it something to read with --input:
#
#   printf 'hello\nfail\npingpong\n' > session.txt
#   detrytus run shell.s --ram-pages 40 --input session.txt

        .equ  RAM_PAGES, 40            # the machine this build is for
        .equ  NPROG, 7                 # sh, ping, pong, hello, fail, pingpong, spin

        .include "include/kernel.s"
        .include "user/sh.s"
        .include "user/ping.s"
        .include "user/pong.s"
        .include "user/hello.s"
        .include "user/fail.s"
        .include "user/pingpong.s"
        .include "user/spin.s"
