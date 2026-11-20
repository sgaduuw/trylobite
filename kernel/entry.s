# Kernel entry: the firmware drops here in ring 0, running on the boot
# address space. Hart 0 sets up traps, the page allocator and the timer,
# spawns program 0 (init), starts the other harts and runs init. The
# other harts enter at ksecondary and look for work.

kentry:
        mv    tp, a1                   # the hart's number, from the firmware
        la    t0, ktrap
        csrw  stvec, t0
        csrw  sscratch, zero           # zero while in the kernel (see ktrap)
        call  klock_take               # the other harts wait until init runs
        la    sp, kstack_top
        la    a0, msg_boot
        call  kputs

        call  page_init
        la    t0, procs
        la    t1, next_slot
        sw    t0, 0(t1)                # spawn starts with slot 0
        li    a1, 0
        call  do_spawn                 # init: everything else is its to start
        bltz  a0, 1f
        call  start_harts
        call  timer_on
        la    s0, procs
        j     pick                     # init, the only process

ksecondary:
        mv    tp, a1
        la    t0, ktrap
        csrw  stvec, t0
        csrw  sscratch, zero
        call  klock_take
        la    sp, kstack_top
        call  timer_on
        la    s0, procs
        j     pick

# timer_on: this hart's first slice, and its timer interrupt enabled.
# Clobbers t0.
timer_on:
        csrr  t0, time
        addi  t0, t0, QUANTUM
        csrw  stimecmp, t0
        li    t0, IE_TIMER
        csrw  sie, t0
        ret

1:      la    a0, msg_noinit
        call  kputs
        li    a0, 98
        j     halt
