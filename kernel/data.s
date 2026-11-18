# Kernel data, from the bottom of its page; the stack grows down from the top.

        .section kdata, P_KDATA * PAGE - 9840

ticks:  .word 0                        # timer interrupts taken

# The process table. .zero starts one tryte below the first word's centre,
# so the table's address is one above where the trytes begin.
procs_raw:
        .zero NPROC * PCB_SIZE
        .equ  procs, procs_raw + 1

numbuf: .zero 16
numbuf_end:

        .equ  kstack_top, P_KDATA * PAGE + 9843

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
