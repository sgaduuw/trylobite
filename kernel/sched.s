# Round-robin scheduling, under the kernel lock. s0 is the process that
# just stopped running on this hart.

        .compress
schedule:
        lw    t0, PCB_STATE(s0)
        li    t1, ST_RUNNING
        bne   t0, t1, pick             # it blocked or exited
        li    t0, ST_READY             # preempted or yielded: it can run again
        sw    t0, PCB_STATE(s0)

# pick: run the next ready process after s0, any record: s0's turn last
# (rk_pick, kernel/rust/trykern/src/sched.rs, which also wakes the
# sleepers whose time has come); or leave, if the platform asked this
# hart to go.
pick:
        addi  t0, tp, HART_MAX
        li    t1, 3
        mul   t0, t0, t1
        la    t1, leaving
        add   t0, t0, t1
        lw    t1, 0(t0)
        bnez  t1, hart_leave
        mv    a0, s0                   # the Rust picks (sched.rs)
        call  rk_pick
        beqz  a0, 1f
        mv    s0, a0                   # it is ST_RUNNING now
        j     resume
1:      call  rk_stuck                 # nobody is ready: why?
        beqz  a0, idle                 # someone may yet wake
        li    t0, 1
        bne   a0, t0, 5f
        la    a0, msg_done             # every process has ended
        call  kputs
        lw    a0, ticks
        call  kputn
        la    a0, msg_ticks
        call  kputs
        li    a0, 0
        j     halt
5:      la    a0, msg_deadlock         # some wait, and nobody can wake them
        call  kputs
        li    a0, 1
        j     halt

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
2:      lw    t1, sleepers             # and for the earliest sleeper's time
        beqz  t1, 2f
        lw    t1, next_wake
        csrw  stimecmp, t1
        addi  t0, t0, IE_TIMER
2:      csrw  sie, t0
        call  klock_give
        wfi
        call  klock_take
        sw    zero, 0(s1)              # in case nobody woke it on purpose
        li    t0, V_HART
1:      lw    t1, HC_RECEIVE(t0)       # empty the mailbox: no wake-up can
        bgez  t1, 1b                   # arrive now, with the entry cleared
        bnez  tp, 3f
        call  rk_hotplug_events
        call  rk_device_irqs
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
        .nocompress
