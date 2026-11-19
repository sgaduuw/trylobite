# The firmware and the kernel, without programs. Include it from a file
# that first defines RAM_PAGES and then adds programs in sections prog0 to
# prog2, each loaded at P_PROGn * PAGE and run at V_USER (see demo.s).
# The kernel starts program 0; programs start others with SYS_SPAWN.

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
        .include "kernel/mm.s"

        .include "kernel/data.s"
        .include "kernel/pagetables.s"
