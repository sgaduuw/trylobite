# The first milestone: two processes, preempted by the timer, passing
# messages through the kernel.
#
#   uv run detrytus run demo.s

        .include "kernel.s"
        .include "user/ping.s"
        .include "user/pong.s"
