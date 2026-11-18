# System calls. The number is in the saved a0, arguments in the saved a1
# and a2; the result goes back into the saved a0.

on_syscall:
        lw    t0, PCB_PC(s0)
        addi  t0, t0, 3                # return past the sys instruction
        sw    t0, PCB_PC(s0)
        lw    a0, PCB_A0(s0)
        lw    a1, PCB_A1(s0)
        lw    a2, PCB_A2(s0)
        li    t0, SYS_PUTC
        beq   a0, t0, sys_putc
        li    t0, SYS_SEND
        beq   a0, t0, sys_send
        li    t0, SYS_RECV
        beq   a0, t0, sys_recv
        li    t0, SYS_YIELD
        beq   a0, t0, sys_yield
        li    t0, SYS_EXIT
        beq   a0, t0, sys_exit
        li    t0, SYS_GETPID
        beq   a0, t0, sys_getpid
        li    t0, SYS_PUTS
        beq   a0, t0, sys_puts
        li    a0, -1                   # no such call

sys_return:                            # a0: the result
        sw    a0, PCB_A0(s0)
        j     resume

sys_putc:
        mv    a0, a1
        call  kputc
        li    a0, 0
        j     sys_return

sys_getpid:
        call  current_pid
        j     sys_return

# puts(address): print a 0-terminated string from the caller's page in one
# go, so preemption cannot split it. Reading user memory needs SUA, and
# the address must lie in the process's page: otherwise a process could
# make the kernel print kernel memory, or fault inside the kernel.
sys_puts:
        li    t3, V_USER - 9841        # the user page's first tryte
        blt   a1, t3, 2f
        li    t3, V_USER + 9841        # and its last
        bgt   a1, t3, 2f
        li    t0, 0t+000
        csrw  ststatus, t0             # SUA on (resume rewrites ststatus anyway)
        li    t5, V_CONSOLE
1:      bgt   a1, t3, 3f               # stop at the end of the page
        lt    t0, 0(a1)
        beqz  t0, 3f
        sw    t0, 0(t5)
        addi  a1, a1, 1
        j     1b
3:      csrw  ststatus, zero           # SUA off again
        li    a0, 0
        j     sys_return
2:      li    a0, -2
        j     sys_return

# send(pid, value): deliver straight to a receiver that is waiting, else
# leave the value in its one-slot mailbox, else report the mailbox full.
sys_send:
        bltz  a1, 1f
        li    t0, NPROC
        bge   a1, t0, 1f
        li    t0, PCB_SIZE
        mul   t1, a1, t0
        la    s1, procs
        add   s1, s1, t1               # s1: the receiver
        lw    t0, PCB_STATE(s1)
        beqz  t0, 1f                   # it has exited
        li    t1, ST_RECV
        beq   t0, t1, 2f
        lw    t0, PCB_FULL(s1)
        bnez  t0, 3f
        sw    a2, PCB_MAIL(s1)
        li    t0, 1
        sw    t0, PCB_FULL(s1)
        li    a0, 0
        j     sys_return
1:      li    a0, -2                   # no such process
        j     sys_return
2:      sw    a2, PCB_A0(s1)           # its recv returns the value
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        li    a0, 0
        j     sys_return
3:      li    a0, -1                   # mailbox full
        j     sys_return

# recv(): take the waiting message, or block until send delivers one.
sys_recv:
        lw    t0, PCB_FULL(s0)
        beqz  t0, 1f
        lw    a0, PCB_MAIL(s0)
        sw    zero, PCB_FULL(s0)
        j     sys_return
1:      li    t0, ST_RECV
        sw    t0, PCB_STATE(s0)
        j     schedule

sys_yield:
        sw    zero, PCB_A0(s0)
        j     schedule

sys_exit:
        la    a0, msg_proc
        call  kputs
        call  current_pid
        call  kputn
        la    a0, msg_exited
        call  kputs
        lw    a0, PCB_A1(s0)
        call  kputn
        li    a0, 10
        call  kputc
        sw    zero, PCB_STATE(s0)
        j     schedule
