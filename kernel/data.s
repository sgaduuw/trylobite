# Kernel data, from the bottom of its page; the stack grows down from the top.

        .section kdata, P_KDATA * PAGE - 9840, P_KDATA * PAGE - 9840 - KOFF

ticks:  .word 0                        # timer interrupts taken
free_head:  .word 0                    # first free page, or 0 for none
free_count: .word 0                    # how many pages are free
next_slot:  .word 0                    # where spawn starts looking (set at boot)

# Where each program image was loaded.
programs:   .word P_PROG0, P_PROG1, P_PROG2

procs:  .words NPROC * PCB_SIZE / 3     # the process table

numbuf: .zero 16
numbuf_end:

        .equ  kstack_top, P_KDATA * PAGE + 9843 - KOFF   # top of the data page

msg_boot:     .string "trylobite: booting\n"
msg_proc:     .string "trylobite: process "
msg_exited:   .string " exited with code "
msg_fault:    .string "trylobite: process "
msg_cause:    .string " faulted, cause "
msg_at:       .string " at address "
msg_done:     .string "trylobite: all processes exited after "
msg_ticks:    .string " timer interrupts\n"
msg_deadlock: .string "trylobite: deadlock, every process is waiting\n"
msg_panic:    .string "trylobite: panic, trap in the kernel, cause "
msg_noinit:   .string "trylobite: cannot start init\n"
