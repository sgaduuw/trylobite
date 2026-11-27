# The firmware and the kernel, without programs: not something to run on
# its own. Include it from a file that first defines NPROG,
# then adds NPROG programs in sections prog0, prog1 and so on, program n
# loaded at (P_PROG0 + n) * PAGE and run at V_USER (see demo.s). The kernel starts
# program 0; programs start others with SYS_SPAWN.

        .assert defined(NPROG), "include/kernel.s is not run on its own: run a file that sets NPROG and includes it, such as demo.s or shell.s"
        .assert (NPROG >= 1) * (NPROG <= NPROG_MAX), "NPROG says how many programs the build adds, from 1 to NPROG_MAX (27)"

        .include "layout.s"
        .equ  P_FREE, P_PROG0 + NPROG     # pages from here to the end of RAM are free
        .include "../firmware/boot.s"            # the boot page, from address 0

        # Code from the bottom of its page: loaded at a physical address, run
        # (and labelled) at the virtual one, KOFF lower.
        .section kernel, P_KCODE * PAGE - 9840, P_KCODE * PAGE - 9840 - KOFF
        .gp   kgp
        .include "../kernel/entry.s"
        .include "../kernel/boot.s"
        .include "../kernel/trap.s"
        .include "../kernel/syscall.s"
        .include "../kernel/sched.s"
        .include "../kernel/console.s"
        .include "../kernel/mm.s"
        .include "../kernel/wait.s"
        .include "../kernel/lock.s"
        .include "../kernel/harts.s"
        .include "../kernel/devices.s"
        .include "../kernel/ipc.s"
        .include "../kernel/desc.s"
        .include "../kernel/names.s"
        .include "../kernel/info.s"
        .include "../kernel/proc.s"
        .include "../kernel/rt.s"

        .include "../kernel/data.s"
        # The Rust part (tools/kernel.py builds it): its code goes on in the
        # kernel section, its data at the end of the data section.
        .include "../kernel/trykern.s"
kcode_end:
        .assert kcode_end <= P_KCODE * PAGE + 9842 - KOFF, "the kernel's code runs off its page"
        .section kdata
kdata_end:
        .assert kdata_end + KSTACK_ROOM <= kstack_top, "kernel data runs into the kernel stack: shrink the process table (NPROC)"
        .include "../kernel/pagetables.s"
