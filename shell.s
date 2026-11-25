# Milestone 3: the kernel starts init, which starts the servers and then
# a shell that runs the programs typed at it. Programs other than
# pingpong live on the disk: put bin/ on one and give the shell
# something to read with --input:
#
#   tools/fs.py new disk.img 20 bin/*.s
#   printf 'hello\nfail\npingpong\n' > session.txt
#   detrytus run shell.s --ram-pages 81 --input session.txt --disk disk.img

        .equ  RAM_PAGES, 81            # the machine this build is for
        .equ  NPROG, 11                # init, ping, pong, pingpong, the file
                                       # server, the disk server, the console
                                       # server, the pipe server, the shell,
                                       # the network server and the IP server
        .equ  INIT_FSD, 4              # the programs init starts, by number
        .equ  INIT_DISKD, 5
        .equ  INIT_CONSD, 6
        .equ  INIT_PIPED, 7
        .equ  INIT_SH, 8
        .equ  INIT_NETD, 9
        .equ  INIT_IPD, 10

        .include "include/kernel.s"
        .section prog0, P_PROG0 * PAGE, V_USER
        .include "user/init.s"
        .include "user/ping.s"
        .include "user/pong.s"
        .include "user/pingpong.s"
        .section prog4, (P_PROG0 + 4) * PAGE, V_USER
        .include "user/fsd.s"
        .section prog5, (P_PROG0 + 5) * PAGE, V_USER
        .include "user/diskd.s"
        .section prog6, (P_PROG0 + 6) * PAGE, V_USER
        .include "user/consd.s"
        .section prog7, (P_PROG0 + 7) * PAGE, V_USER
        .include "user/piped.s"
        .section prog8, (P_PROG0 + 8) * PAGE, V_USER
        .include "user/sh.s"
        .section prog9, (P_PROG0 + 9) * PAGE, V_USER
        .include "user/netd.s"
        .section prog10, (P_PROG0 + 10) * PAGE, V_USER
        .include "user/ipd.s"
