# Kernel entry: the firmware drops here in ring 0, running on the boot
# address space. Set up traps, the page allocator and the timer, spawn
# program 0 (init), and start it.

kentry:
        la    sp, kstack_top
        la    t0, ktrap
        csrw  stvec, t0
        csrw  sscratch, zero           # zero while in the kernel (see ktrap)
        la    a0, msg_boot
        call  kputs

        call  page_init
        la    t0, procs
        la    t1, next_slot
        sw    t0, 0(t1)                # spawn starts with slot 0
        li    a1, 0
        call  do_spawn                 # init: everything else is its to start
        bltz  a0, 1f

        # The timer: first slice, then enable its interrupt (sie trit 1).
        csrr  t0, time
        addi  t0, t0, QUANTUM
        csrw  stimecmp, t0
        li    t0, 0t+0
        csrw  sie, t0

        la    s0, procs                # init is process 0
        j     resume

1:      la    a0, msg_noinit
        call  kputs
        li    a0, 98
        j     halt
