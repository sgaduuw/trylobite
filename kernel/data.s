# Kernel data, from the bottom of its page; the stack grows down from the top.

        .section kdata, P_KDATA * PAGE - 9840, P_KDATA * PAGE - 9840 - KOFF

# The small globals come first and the process table after them, so that
# gp, 363 trytes above the first, reaches all of them and the table's start
# with a compressed instruction (c.lagp, c.lwgp, c.swgp reach +-363).
ticks:  .word 0                        # timer interrupts taken
        .equ  kgp, ticks + 363
free_head:  .word 0                    # first free page, or 0 for none
free_count: .word 0                    # how many pages are free
fresh_page: .word 0                    # the first page never handed out
ram_pages:  .word 0                    # pages of RAM the kernel uses (rk_page_init)
next_slot:  .word 0                    # where spawn starts looking (set at boot)
nprog:      .word NPROG                # program images this build loaded
log_base:   .word 0                    # the log page's first tryte, through the
                                       # direct map; 0 until boot gives it one
log_pos:    .word 0                    # code points ever printed (console.s)
sleepers:   .word 0                    # 1 while a process may sleep or have an alarm set
next_wake:  .word 0                    # ... and the earliest time one waits for
nready:     .word 0                    # how many processes are ST_READY (rk_pick)

klock:  .word 0                        # the kernel lock: 1 while a hart holds it
idle_harts: .words NHART               # 1: the hart waits for work, by index
leaving: .words NHART                  # 1: the platform asked the hart to go

irq_armed: .word 0                     # sources armed by their drivers
drivers: .words NSRC                   # each source's driver's record, 0 for
                                       # none (devices.rs)

procs:  .words NPROC * PCB_SIZE / 3     # the process table
        .assert procs - kgp <= 363, "the process table starts out of c.lagp's reach of gp: move kgp"

epochs: .words NPROC                   # tenants each slot has had (see resume)
seen:   .words NHART * NPROC           # the epoch each hart last flushed, by slot
fpu_owner: .words NHART                # whose bank each hart's coprocessor
                                       # holds: a record, or 0 (see resume)

names:  .words NSRV * SRV / 3          # server names (rust/trykern/src/names.rs)


numbuf: .zero 16
numbuf_end:

        .equ  kstack_top, P_KDATA * PAGE + 9843 - KOFF   # top of the data page

kversion:     .string "0.1.0"         # pyproject.toml's version (tests/test_boot.py)
msg_version:  .string "trylobite: version "
msg_about:    .string ", a microkernel for detrytus, the balanced-ternary machine\n"
msg_memory:   .string "trylobite: memory: "
msg_pages:    .string " pages ("
msg_trytes:   .string " trytes), "
msg_free:     .string " free\n"
msg_harts:    .string "trylobite: harts: "
msg_irq:      .string "trylobite: irq0: interrupt controller, "
msg_irq_at:   .string " sources"
msg_cons:     .string "trylobite: cons0: console"
msg_disk:     .string "trylobite: disk0: block device, "
msg_blocks:   .string " blocks"
msg_nodisk:   .string "no disk"
msg_net:      .string "trylobite: net0: network device, "
msg_nolink:   .string "no link"
msg_empty:    .string ""
msg_atpage:   .string ", at page "
msg_slots:    .string "trylobite: process table: "
msg_progs:    .string " slots, "
msg_image:    .string " programs in the image\n"
msg_init:     .string "trylobite: starting init\n"
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
msg_rpanic:   .string "trylobite: panic in the kernel's Rust\n"
msg_hart:     .string "trylobite: hart "
msg_joined:   .string " joined\n"
msg_left:     .string " left\n"

# The stack grows down from kstack_top towards the data: keep it room.
        .equ  KSTACK_ROOM, 2187        # trytes, far more than the deepest call
                                       # (include/kernel.s checks it, after the
                                       # Rust part's data)
