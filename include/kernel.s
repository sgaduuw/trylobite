# The firmware and the kernel, without programs: not something to run on
# its own. Include it from a file that first defines RAM_PAGES and NPROG,
# then adds NPROG programs in sections prog0, prog1 and so on, each loaded
# at P_PROGn * PAGE and run at V_USER (see demo.s). The kernel starts
# program 0; programs start others with SYS_SPAWN.

        .assert defined(RAM_PAGES) * defined(NPROG), "include/kernel.s is not run on its own: run a file that sets RAM_PAGES and NPROG and includes it, such as demo.s or shell.s"
        .assert (NPROG >= 1) * (NPROG <= 6), "NPROG says how many programs the build adds, from 1 to 6"

        .include "layout.s"
        .include "../firmware/boot.s"            # the boot page, from address 0

        # Code from the bottom of its page: loaded at a physical address, run
        # (and labelled) at the virtual one, KOFF lower.
        .section kernel, P_KCODE * PAGE - 9840, P_KCODE * PAGE - 9840 - KOFF
        .gp   kgp
        .include "../kernel/entry.s"
        .include "../kernel/trap.s"
        .include "../kernel/syscall.s"
        .include "../kernel/sched.s"
        .include "../kernel/console.s"
        .include "../kernel/mm.s"
        .include "../kernel/wait.s"
        .include "../kernel/lock.s"
        .include "../kernel/harts.s"
        .include "../kernel/devices.s"

        .include "../kernel/data.s"
        .include "../kernel/pagetables.s"
