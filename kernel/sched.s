# Round-robin scheduling, under the kernel lock. s0 is the process that
# just stopped running on this hart.

schedule:
        lw    t0, PCB_STATE(s0)
        li    t1, ST_RUNNING
        bne   t0, t1, pick             # it blocked or exited
        li    t0, ST_READY             # preempted or yielded: it can run again
        sw    t0, PCB_STATE(s0)

# pick: run the next ready process after s0, any record: s0's turn last;
# or leave, if the platform asked this hart to go.
pick:
        addi  t0, tp, HART_MAX
        li    t1, 3
        mul   t0, t0, t1
        la    t1, leaving
        add   t0, t0, t1
        lw    t1, 0(t0)
        bnez  t1, hart_leave
        la    t2, procs
        li    t0, NPROC * PCB_SIZE
        add   t3, t2, t0               # t3: just past the table
        mv    s1, s0
        li    t4, NPROC                # look at every process, s0's turn last
1:      addi  s1, s1, PCB_SIZE
        blt   s1, t3, 2f
        mv    s1, t2                   # wrap around
2:      lw    t0, PCB_STATE(s1)
        li    t1, ST_READY
        beq   t0, t1, 3f
        addi  t4, t4, -1
        bnez  t4, 1b

        # Nobody is ready. A process running on another hart can still
        # send or spawn, and a device can still wake a reader: wait for
        # work.
        mv    s1, t2
6:      lw    t0, PCB_STATE(s1)
        li    t1, ST_RUNNING
        beq   t0, t1, idle
        li    t1, ST_GETC
        beq   t0, t1, idle
        li    t1, ST_DISK
        beq   t0, t1, idle
        addi  s1, s1, PCB_SIZE
        blt   s1, t3, 6b

        # Nothing runs anywhere. Someone still waiting means nobody will
        # wake them.
        mv    s1, t2
4:      lw    t0, PCB_STATE(s1)
        li    t1, ST_RECV
        beq   t0, t1, 5f
        addi  s1, s1, PCB_SIZE
        blt   s1, t3, 4b
        la    a0, msg_done
        call  kputs
        la    t0, ticks
        lw    a0, 0(t0)
        call  kputn
        la    a0, msg_ticks
        call  kputs
        li    a0, 0
        j     halt
5:      la    a0, msg_deadlock
        call  kputs
        li    a0, 1
        j     halt

3:      li    t0, ST_RUNNING
        sw    t0, PCB_STATE(s1)
        mv    s0, s1
        j     resume

# idle: offer this hart for work (wake_one rings its doorbell), let the
# lock go and wait. The doorbell stays rung while a word waits in this
# hart's mailbox, so a wake-up sent between giving the lock and the wfi
# is not lost. Only the doorbell is enabled meanwhile: a pending timer
# would end every wait at once.
idle:
        mv    t0, tp
        addi  t0, t0, HART_MAX
        li    t1, 3
        mul   t0, t0, t1
        la    t1, idle_harts
        add   s1, t0, t1               # s1: this hart's entry
        li    t0, 1
        sw    t0, 0(s1)
        li    t0, IE_SOFT
        bnez  tp, 2f
        li    t0, IE_SOFT + IE_EXT     # hart 0 also wakes for hot-plug events
2:      csrw  sie, t0
        call  klock_give
        wfi
        call  klock_take
        sw    zero, 0(s1)              # in case nobody woke it on purpose
        li    t0, V_HART
1:      lw    t1, HC_RECEIVE(t0)       # empty the mailbox: no wake-up can
        bgez  t1, 1b                   # arrive now, with the entry cleared
        bnez  tp, 3f
        call  hotplug_events
        call  device_irqs
3:      call  timer_on
        j     pick

# a0 = the number of the process in s0.
current_pid:
        la    t0, procs
        sub   t0, s0, t0
        li    t1, PCB_SIZE
        div   a0, t0, t1
        ret

# Power off with exit code a0.
halt:
        li    t0, V_POWER
        sw    a0, 0(t0)
