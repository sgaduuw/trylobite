# Milestone 3: the kernel starts a shell, which runs the programs typed
# at it. Programs other than pingpong live on the disk: put bin/ on one
# and give the shell something to read with --input:
#
#   tools/fs.py new disk.img 20 bin/*.s
#   printf 'hello\nfail\npingpong\n' > session.txt
#   detrytus run shell.s --ram-pages 81 --input session.txt --disk disk.img

        .equ  RAM_PAGES, 81            # the machine this build is for
        .equ  NPROG, 7                 # sh, ping, pong, pingpong, the file server,
                                       # the disk server, the console server
        .equ  SH_FSD, 4                # which sh starts, after
        .equ  SH_DISKD, 5              # this one, after
        .equ  SH_CONSD, 6              # this one

        .include "include/kernel.s"
        .include "user/sh.s"
        .include "user/ping.s"
        .include "user/pong.s"
        .include "user/pingpong.s"
        .section prog4, P_PROG4 * PAGE, V_USER
        .include "user/fsd.s"
        .section prog5, P_PROG5 * PAGE, V_USER
        .include "user/diskd.s"
        .section prog6, P_PROG6 * PAGE, V_USER
        .include "user/consd.s"
