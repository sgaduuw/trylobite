# Milestone 2: the kernel starts init, which spawns pong and ping; they
# pass messages, preempted by the timer, and their memory is reclaimed.
#
#   detrytus run demo.s --harts 3
        .equ  NPROG, 3                 # init, ping and pong

        .include "include/kernel.s"
        .include "user/demo-init.s"
        .include "user/ping.s"
        .include "user/pong.s"
