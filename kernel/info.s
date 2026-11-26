# What the kernel tells about itself, for system tools: its log
# (bin/dmesg) and a summary of the machine and its use (bin/uname,
# bin/uptime, bin/free). The kernel only reports; the tools format.

        .compress
# log(buffer, n, from): copy at most n code points of the log, from the
# from-th the kernel ever printed, to buffer: a0 = how many, a1 = where
# the next read starts. A reader that fell behind starts at the oldest
# the log still keeps; one ahead of the log gets 0. A buffer that runs
# off the end of its page gets as many as fit.
sys_log:
        bltz  a2, 8f
        lw    t3, log_pos              # t3: code points ever printed
        lw    t4, PCB_A3(s0)           # t4: where the copy starts
        li    t0, LOG_SIZE
        sub   t0, t3, t0               # the oldest kept
        bge   t4, t0, 1f
        mv    t4, t0
1:      bgez  t4, 1f
        li    t4, 0
1:      ble   t4, t3, 1f
        mv    t4, t3
1:      sub   t5, t3, t4               # t5: how many there are to copy
        ble   t5, a2, 1f
        mv    t5, a2
1:      beqz  t5, 3f
        mv    a0, s0
        call  uva                      # a1: the buffer
        beqz  a0, 9f
        ble   t5, a1, 1f
        mv    t5, a1                   # as many as fit in its page
1:      mv    a1, t4
        li    t1, LOG_SIZE
        lw    t2, log_base
        mv    a2, t5
2:      rem   t0, a1, t1               # from is never negative here
        add   t0, t0, t2
        lt    t0, 0(t0)
        st    t0, 0(a0)
        addi  a0, a0, 1
        addi  a1, a1, 1
        addi  a2, a2, -1
        bnez  a2, 2b
3:      add   t4, t4, t5
        sw    t4, PCB_A1(s0)
        mv    a0, t5
        j     sys_return
8:      li    a0, E_INVAL
        j     sys_return
9:      li    a0, E_FAULT
        j     sys_return

# info(buffer): the SI_ words at buffer: the clock, memory, the process
# table and harts, and the kernel's version.
sys_info:
        li    t0, 3
        rem   t0, a1, t0
        bnez  t0, 9b                   # words must be aligned
        addi  a1, a1, SI_TIME - 1
        mv    a0, s0
        call  uva
        beqz  a0, 9b
        li    t0, SYSINFO
        blt   a1, t0, 9b               # not all in one page
        addi  s1, a0, 1 - SI_TIME      # s1: the buffer, as its words see it
        csrr  t0, time
        sw    t0, SI_TIME(s1)
        lw    t0, ticks
        sw    t0, SI_TICKS(s1)
        lw    t0, ram_pages
        sw    t0, SI_PAGES(s1)
        lw    t0, free_count
        sw    t0, SI_FREE(s1)
        li    t0, NPROC
        sw    t0, SI_NPROC(s1)
        li    t1, 0                    # slots in use
        la    t2, procs
        li    t0, NPROC * PCB_SIZE
        add   t3, t2, t0
1:      lw    t0, PCB_STATE(t2)
        beqz  t0, 2f
        addi  t1, t1, 1
2:      addi  t2, t2, PCB_SIZE
        blt   t2, t3, 1b
        sw    t1, SI_PROCS(s1)
        call  harts_present
        sw    a0, SI_HARTS(s1)
        la    t0, kversion             # the version, 0-padded
        addi  t1, s1, SI_RELEASE
        li    t2, RELEASE_MAX + 1
1:      lt    t3, 0(t0)
        st    t3, 0(t1)
        beqz  t3, 2f
        addi  t0, t0, 1
2:      addi  t1, t1, 1
        addi  t2, t2, -1
        bnez  t2, 1b
        addi  t1, t1, -1               # the last is always the end
        st    zero, 0(t1)
        li    a0, 0
        j     sys_return
        .nocompress
