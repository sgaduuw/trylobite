# The firmware and the kernel, without user programs. Include this from a
# file that adds programs in sections user0 and user1 (see demo.s).

        .include "include/layout.s"
        .include "firmware/boot.s"               # the boot page, from address 0

        .section kernel, P_KCODE * PAGE - 9840   # code from the bottom of its page
        .include "kernel/entry.s"
        .include "kernel/trap.s"
        .include "kernel/syscall.s"
        .include "kernel/sched.s"
        .include "kernel/console.s"

        .include "kernel/data.s"
        .include "kernel/pagetables.s"
