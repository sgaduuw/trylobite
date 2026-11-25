# Processes as system tools see them: what each is (proc, name), and
# waiting for the clock (sleep). The kernel keeps a name and a count of
# user-mode ticks in each record for this; the tools format.

        .compress
# proc(pid, buffer): the PI_ words of process pid at buffer.
sys_proc:
        bltz  a1, 8f
        li    t0, NPROC
        bge   a1, t0, 8f
        li    t0, PCB_SIZE
        mul   t0, a1, t0
        la    s1, procs
        add   s1, s1, t0               # s1: its record
        lw    t0, PCB_STATE(s1)
        beqz  t0, 8f                   # a free slot
        li    t0, 3
        rem   t0, a2, t0
        bnez  t0, 9f                   # words must be aligned
        addi  a1, a2, PI_STATE - 1
        mv    a0, s0
        call  uva
        beqz  a0, 9f
        li    t0, PROCINFO
        blt   a1, t0, 9f               # not all in one page
        addi  s2, a0, 1 - PI_STATE     # s2: the buffer, as its words see it
        lw    t0, PCB_STATE(s1)
        sw    t0, PI_STATE(s2)
        lw    t1, PCB_PARENT(s1)
        sw    t1, PI_PARENT(s2)
        li    t1, 0                    # pages: none once it has ended
        li    t2, ST_ZOMBIE
        beq   t0, t2, 2f
        li    t1, PAGES_PER_PROCESS    # its own, and each image page above it
        mv    t2, s1                   # and window it has
        li    t3, NXPAGE + NWIN
1:      lw    t0, PCB_XPAGES(t2)
        beqz  t0, 0f
        addi  t1, t1, 1
0:      addi  t2, t2, 3
        addi  t3, t3, -1
        bnez  t3, 1b
2:      sw    t1, PI_PAGES(s2)
        lw    t0, PCB_CPU(s1)
        sw    t0, PI_CPU(s2)
        li    t2, PROC_NAME
        addi  t0, s1, PCB_NAME
        addi  t1, s2, PI_NAME
1:      lt    t3, 0(t0)
        st    t3, 0(t1)
        addi  t0, t0, 1
        addi  t1, t1, 1
        addi  t2, t2, -1
        bnez  t2, 1b
        li    a0, 0
        j     sys_return
8:      li    a0, E_NOPROC
        j     sys_return
9:      li    a0, E_FAULT
        j     sys_return

# name(string): name the caller after the string at a1.
sys_name:
        mv    a0, s0
        call  uva
        beqz  a0, 9b
        mv    s1, s0
        call  proc_name
        li    a0, 0
        j     sys_return

# proc_name: name the process whose record is s1 after the string at
# kernel address a0, with a1 trytes of it mapped: its part after the
# last /, PROC_NAME_MAX code points of it at most, 0-padded.
# Clobbers a0, a1, t0..t3.
proc_name:
        mv    t1, a0                   # t1: where the name starts so far
1:      blez  a1, 2f                   # the end of what is mapped
        lt    t0, 0(a0)
        beqz  t0, 2f
        addi  a0, a0, 1
        addi  a1, a1, -1
        li    t2, '/'
        bne   t0, t2, 1b
        mv    t1, a0                   # it starts after the /
        j     1b
2:      sub   a1, a0, t1               # a1: its length
        li    t0, PROC_NAME_MAX
        ble   a1, t0, 0f
        mv    a1, t0
0:      addi  t2, s1, PCB_NAME
        li    t3, PROC_NAME
3:      li    t0, 0
        blez  a1, 4f
        lt    t0, 0(t1)
        addi  t1, t1, 1
        addi  a1, a1, -1
4:      st    t0, 0(t2)
        addi  t2, t2, 1
        addi  t3, t3, -1
        bnez  t3, 3b
        ret

# sleep(until): wait until the clock reaches until. wake_sleepers, which
# pick runs while anyone sleeps, makes it ready again; a hart with
# nothing to run sets its timer for the earliest (idle, sched.s).
sys_sleep:
        csrr  t0, time
        bge   t0, a1, 1f               # that time has come
        li    t0, ST_SLEEP             # its saved a1 keeps the time
        sw    t0, PCB_STATE(s0)
        sw    zero, PCB_A0(s0)         # what it returns once woken
        li    t0, 1
        sw    t0, sleepers
        j     schedule
1:      li    a0, 0
        j     sys_return

# alarm(until): set the caller's alarm, or cancel it with NO_ALARM. It
# waits with the sleepers: wake_sleepers rings it.
sys_alarm:
        sw    zero, PCB_ALARM(s0)
        bltz  a1, 1f                   # NO_ALARM
        bgtz  a1, 2f
        li    a1, 1                    # 0 means none: time 1 has come as surely
2:      sw    a1, PCB_ALARM(s0)
        li    t0, 1
        sw    t0, sleepers
1:      li    a0, 0
        j     sys_return

# wake_sleepers: make ready each sleeper whose time has come, and ring
# each alarm whose time has come (its receive gives NOTE_ALARM); sleepers
# becomes whether any still sleep or have an alarm set, and next_wake the
# earliest time one waits for. Clobbers a0, a1, s1, t0..t5.
wake_sleepers:
        mv    t5, ra
        csrr  a1, time
        li    a0, 0                    # a0: 1 once one still sleeps
        la    t4, procs
1:      lw    t0, PCB_ALARM(t4)
        beqz  t0, 4f
        bgt   t0, a1, 5f
        sw    zero, PCB_ALARM(t4)      # it rings
        li    t0, 1
        sw    t0, PCB_RANG(t4)
        mv    s1, t4
        call  rouse                    # clobbers t0, t1 (and wake_one's)
        csrr  a1, time
        j     4f
5:      beqz  a0, 6f                   # the earliest so far?
        lw    t1, next_wake
        bge   t0, t1, 4f
6:      sw    t0, next_wake
        li    a0, 1
4:      lw    t0, PCB_STATE(t4)
        li    t1, ST_SLEEP
        bne   t0, t1, 3f
        lw    t0, PCB_A1(t4)
        bgt   t0, a1, 2f
        li    t0, ST_READY
        sw    t0, PCB_STATE(t4)
        call  wake_one                 # an idle hart can run it
        j     3f
2:      beqz  a0, 0f                   # the earliest so far?
        lw    t1, next_wake
        bge   t0, t1, 3f
0:      sw    t0, next_wake
        li    a0, 1
3:      addi  t4, t4, PCB_SIZE
        la    t0, procs + NPROC * PCB_SIZE
        blt   t4, t0, 1b
        sw    a0, sleepers
        jalr  zero, 0(t5)
        .nocompress
