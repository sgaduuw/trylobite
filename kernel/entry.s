# Kernel entry: the firmware drops here in ring 0, running on the boot
# address space. Hart 0 sets up traps and the page allocator, says what
# it found (boot.rs), spawns program 0 (init), starts the other harts and
# the timer and runs init. The other harts enter at ksecondary and look
# for work.

        .compress
kentry:
        la    gp, kgp                  # every global is reached through gp
        mv    tp, a1                   # the hart's number, from the firmware
        la    t0, ktrap
        csrw  stvec, t0
        li    t0, 0                    # csrw from zero would only read
        csrw  sscratch, t0             # zero while in the kernel (see ktrap)
        call  klock_take               # the other harts wait until init runs
        la    sp, kstack_top
        call  rk_page_init             # the free pages (mm.rs)
        call  log_init                 # the log keeps the boot report too
        call  rk_boot_report           # what it found, before init runs
        call  rk_spawn_init            # init: everything else is its to start
        beqz  a0, 1f
        call  rk_start_harts
        call  timer_on
        la    s0, procs
        j     pick                     # init, the only process

ksecondary:
        la    gp, kgp
        mv    tp, a1
        la    t0, ktrap
        csrw  stvec, t0
        li    t0, 0
        csrw  sscratch, t0
        call  klock_take
        la    sp, kstack_top
        call  timer_on
        la    s0, procs
        j     pick

# timer_on: this hart's first slice, and its timer interrupt enabled;
# on hart 0, hot-plug events too. Clobbers t0.
timer_on:
        csrr  t0, time
        addi  t0, t0, QUANTUM
        csrw  stimecmp, t0
        li    t0, IE_TIMER
        bnez  tp, 1f
        li    t0, IE_TIMER + IE_EXT
1:      csrw  sie, t0
        ret

1:      la    a0, msg_noinit
        call  kputs
        li    a0, 98
        j     halt
        .nocompress
