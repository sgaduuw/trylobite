# The firmware and the kernel, without user programs. Include this from a
# file that adds programs in sections user0 and user1, each loaded at its
# physical page and run at V_USER (see demo.s and user/).

        .include "include/layout.s"
        .include "firmware/boot.s"               # the boot page, from address 0

        # Code from the bottom of its page: loaded at a physical address, run
        # (and labelled) at the virtual one, KOFF lower.
        .section kernel, P_KCODE * PAGE - 9840, P_KCODE * PAGE - 9840 - KOFF
        .include "kernel/entry.s"
        .include "kernel/trap.s"
        .include "kernel/syscall.s"
        .include "kernel/sched.s"
        .include "kernel/console.s"

        .include "kernel/data.s"
        .include "kernel/pagetables.s"
