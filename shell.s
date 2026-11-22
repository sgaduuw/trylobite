# Milestone 3: the kernel starts a shell, which runs the programs typed
# at it. Programs other than pingpong live on the disk: put bin/ on one
# and give the shell something to read with --input:
#
#   tools/fs.py new disk.img 20 bin/*.s
#   printf 'hello\nfail\npingpong\n' > session.txt
#   detrytus run shell.s --ram-pages 40 --input session.txt --disk disk.img

        .equ  RAM_PAGES, 40            # the machine this build is for
        .equ  NPROG, 5                 # sh, ping, pong, pingpong, the file server
        .equ  SH_FSD, 4                # which sh starts first

        .include "include/kernel.s"
        .include "user/sh.s"
        .include "user/ping.s"
        .include "user/pong.s"
        .include "user/pingpong.s"
        .section prog4, P_PROG4 * PAGE, V_USER
        .include "user/fsd.s"
