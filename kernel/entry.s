# Kernel entry: the firmware drops here in ring 0, already running on
# process 0's page table. Set up traps, the process table and the timer,
# then start process 0.

kentry:
        la    sp, kstack_top
        la    t0, ktrap
        csrw  stvec, t0
        csrw  sscratch, zero           # zero while in the kernel (see ktrap)
        la    a0, msg_boot
        call  kputs

        # Both processes start at V_USER with their own page table.
        la    s0, procs
        li    t0, PTBR0
        sw    t0, PCB_PTBR(s0)
        addi  s1, s0, PCB_SIZE
        li    t0, PTBR1
        sw    t0, PCB_PTBR(s1)
        li    t0, V_USER
        li    t1, USER_SP
        li    t2, ST_READY
        sw    t0, PCB_PC(s0)
        sw    t1, 0(s0)
        sw    t2, PCB_STATE(s0)
        sw    t0, PCB_PC(s1)
        sw    t1, 0(s1)
        sw    t2, PCB_STATE(s1)

        # The timer: first slice, then enable its interrupt (sie trit 1).
        csrr  t0, time
        addi  t0, t0, QUANTUM
        csrw  stimecmp, t0
        li    t0, 0t+0
        csrw  sie, t0

        j     resume                   # s0 = process 0
