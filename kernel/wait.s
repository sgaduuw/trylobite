# Processes ending and their parents waiting: wait, and burying a process
# once release has freed its pages. Exit codes outlive their process in
# its record, which stays as ST_ZOMBIE until its parent waits for it.
# How a process ended is kept in its saved a0 (WAIT_EXITED or
# WAIT_FAULTED) and a1 (the code or the cause): the very registers its
# parent's wait returns.

        .compress
# wait(pid): how child pid ended, in a0 and a1; block until it has.
sys_wait:
        call  find_child
        bltz  a0, sys_return
        lw    t0, PCB_STATE(s1)
        li    t1, ST_ZOMBIE
        bne   t0, t1, 1f
        lw    t0, PCB_A1(s1)           # it has ended: reap it
        sw    t0, PCB_A1(s0)
        lw    a0, PCB_A0(s1)
        sw    zero, PCB_STATE(s1)
        j     sys_return
1:      li    t0, ST_WAIT              # its bury hands over a0 and a1
        sw    t0, PCB_STATE(s0)
        j     schedule

# kill(pid): end child pid. It goes the next time the kernel would run
# it, which for one running on another hart is its next trap, within a
# timer slice; its parent's wait then reports WAIT_KILLED.
sys_kill:
        call  find_child
        bltz  a0, sys_return
        mv    a0, a1
        call  kill_pid
        li    a0, 0
        j     sys_return

# find_child: s1 = the record of process a1, and a0 = 0, if it is a child
# of the process in s0 (ended or not); else a0 = E_NOCHILD. Clobbers t0, t1.
find_child:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  current_pid              # a0: the caller's number
        bltz  a1, 8f
        li    t0, NPROC
        bge   a1, t0, 8f
        li    t0, PCB_SIZE
        mul   t1, a1, t0
        la    s1, procs
        add   s1, s1, t1               # s1: the child
        lw    t0, PCB_STATE(s1)
        beqz  t0, 8f                   # a free slot is nobody's child
        lw    t1, PCB_PARENT(s1)
        bne   t1, a0, 8f
        li    a0, 0
        j     9f
8:      li    a0, E_NOCHILD
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# kill_pid: mark process a0 killed, if it has not ended; on_kill ends it
# the next time the kernel would run it (ktrap, resume). One blocked in
# recv, wait or getc is made ready for that, since nothing else would
# wake it; one in the disk queue keeps its place, because the disk may be
# writing into its block window. Clobbers a0 and t0..t3.
kill_pid:
        li    t0, PCB_SIZE
        mul   t0, a0, t0
        la    t1, procs
        add   t0, t0, t1               # t0: its record
        lw    t1, PCB_STATE(t0)
        beqz  t1, 9f                   # already gone
        li    t2, ST_ZOMBIE
        beq   t1, t2, 9f
        li    t2, 1
        sw    t2, PCB_KILLED(t0)
        bgtz  t1, 9f                   # ready or running: it goes when next run
        li    t2, ST_DISK
        beq   t1, t2, 9f               # disk_irq readies it
        li    t2, ST_READY
        sw    t2, PCB_STATE(t0)
        j     wake_one                 # returns to our caller
9:      ret

# bury: the process in s0 has ended and its pages are free. Orphan its
# children, freeing those already ended, since nobody can wait for them
# now; hand how it ended to its parent if the parent waits for it, else
# stay as a zombie until the parent does. A process with no parent
# simply goes. Does not return.
bury:
        call  current_pid
        mv    t4, a0                   # t4: its number
        call  ipc_ended                # servers learn of it (ipc.s)
        call  srv_ended                # its names go (names.s)
        lw    t0, foreground
        bne   t0, t4, 0f
        li    t0, NO_FOREGROUND        # the console goes back to nobody
        sw    t0, foreground
        call  console_arm
0:        la    s1, procs
        li    t3, NPROC * PCB_SIZE
        add   t3, s1, t3               # t3: just past the table
1:      lw    t0, PCB_PARENT(s1)
        bne   t0, t4, 2f
        li    t0, NO_PARENT
        sw    t0, PCB_PARENT(s1)
        lw    t0, PCB_STATE(s1)
        li    t1, ST_ZOMBIE
        bne   t0, t1, 2f
        sw    zero, PCB_STATE(s1)
2:      addi  s1, s1, PCB_SIZE
        blt   s1, t3, 1b

        lw    t0, PCB_PARENT(s0)
        bltz  t0, 4f                   # nobody to tell
        li    t1, PCB_SIZE
        mul   t0, t0, t1
        la    s1, procs
        add   s1, s1, t0               # s1: the parent
        lw    t0, PCB_STATE(s1)
        li    t1, ST_WAIT
        bne   t0, t1, 3f
        lw    t0, PCB_A1(s1)
        bne   t0, t4, 3f               # it waits for another child
        lw    t0, PCB_A0(s0)
        sw    t0, PCB_A0(s1)
        lw    t0, PCB_A1(s0)
        sw    t0, PCB_A1(s1)
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        call  wake_one                 # a hart waiting for work can run it
        j     4f
3:      li    t0, ST_ZOMBIE
        sw    t0, PCB_STATE(s0)
        j     schedule
4:      sw    zero, PCB_STATE(s0)
        j     schedule
        .nocompress
