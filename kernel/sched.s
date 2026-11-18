# Round-robin scheduling. s0 is the process that just stopped running.

schedule:
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

        # Nobody can run. Someone still waiting means nobody will wake them.
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

3:      mv    s0, s1
        j     resume

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
