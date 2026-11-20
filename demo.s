# Milestone 2: the kernel starts init, which spawns pong and ping; they
# pass messages, preempted by the timer, and their memory is reclaimed.
#
#   detrytus run demo.s --ram-pages 40 --harts 3

        .equ  RAM_PAGES, 40            # the machine this build is for

        .include "kernel.s"
        .include "user/init.s"
        .include "user/ping.s"
        .include "user/pong.s"
