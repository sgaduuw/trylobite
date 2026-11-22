# Kernel data, from the bottom of its page; the stack grows down from the top.

        .section kdata, P_KDATA * PAGE - 9840, P_KDATA * PAGE - 9840 - KOFF

# The small globals come first and the process table after them, so that
# gp, 363 trytes above the first, reaches all of them and the table's start
# with a compressed instruction (c.lagp, c.lwgp, c.swgp reach +-363).
ticks:  .word 0                        # timer interrupts taken
        .equ  kgp, ticks + 363
free_head:  .word 0                    # first free page, or 0 for none
free_count: .word 0                    # how many pages are free
next_slot:  .word 0                    # where spawn starts looking (set at boot)

klock:  .word 0                        # the kernel lock: 1 while a hart holds it
idle_harts: .words NHART               # 1: the hart waits for work, by index
leaving: .words NHART                  # 1: the platform asked the hart to go

irq_armed: .word 0                     # sources armed by their drivers
drivers: .words NSRC                   # each source's driver's record, 0 for
                                       # none (devices.s)

procs:  .words NPROC * PCB_SIZE / 3     # the process table
        .assert procs - kgp <= 363, "the process table starts out of c.lagp's reach of gp: move kgp"

epochs: .words NPROC                   # tenants each slot has had (see resume)
seen:   .words NHART * NPROC           # the epoch each hart last flushed, by slot

names:  .words NSRV * SRV / 3          # server names (names.s)
srv_key: .zero SRV_NAME_MAX + 1        # the name a call gave, zero-padded


numbuf: .zero 16
numbuf_end:

        .equ  kstack_top, P_KDATA * PAGE + 9843 - KOFF   # top of the data page

msg_boot:     .string "trylobite: booting\n"
msg_proc:     .string "trylobite: process "
msg_exited:   .string " exited with code "
msg_killed:   .string " killed\n"
msg_fault:    .string "trylobite: process "
msg_cause:    .string " faulted, cause "
msg_at:       .string " at address "
msg_done:     .string "trylobite: all processes exited after "
msg_ticks:    .string " timer interrupts\n"
msg_deadlock: .string "trylobite: deadlock, every process is waiting\n"
msg_panic:    .string "trylobite: panic, trap in the kernel, cause "
msg_noinit:   .string "trylobite: cannot start init\n"
msg_hart:     .string "trylobite: hart "
msg_joined:   .string " joined\n"
msg_left:     .string " left\n"

# The stack grows down from kstack_top towards the data: keep it room.
        .equ  KSTACK_ROOM, 2187        # trytes, far more than the deepest call
kdata_end:
        .assert kdata_end + KSTACK_ROOM <= kstack_top, "kernel data runs into the kernel stack: shrink the process table (NPROC)"
