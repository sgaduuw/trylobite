# System calls. The number is in the saved a0, arguments in the saved a1
# and a2; the result goes back into the saved a0.

        .compress
on_syscall:
        csrr  t0, stval                # the instruction after the sys: tpc + 3
        sw    t0, PCB_PC(s0)           # is wrong when the sys is in a bundle
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
        li    t0, SYS_SPAWN
        beq   a0, t0, sys_spawn
        li    t0, SYS_HART
        beq   a0, t0, sys_hart
        li    t0, SYS_GETC
        beq   a0, t0, sys_getc
        li    t0, SYS_WAIT
        beq   a0, t0, sys_wait
        li    t0, SYS_BREAD
        li    a2, BLOCK_READ
        beq   a0, t0, sys_block
        li    t0, SYS_BWRITE
        li    a2, BLOCK_WRITE
        beq   a0, t0, sys_block
        li    a0, E_NOCALL

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

sys_hart:
        mv    a0, tp
        j     sys_return

# puts(address): print a 0-terminated string from the caller's page in one
# go, so preemption cannot split it. Reading user memory needs SUA, and
# the address must lie in the process's page: otherwise a process could
# make the kernel print kernel memory, or fault inside the kernel.
# puts(address): the string may be in the process's page or, once it has
# one, its block window just above.
sys_puts:
        li    t3, V_USER - 9841        # the user page's first tryte
        blt   a1, t3, 2f
        li    t3, V_USER + 9841        # and its last
        lw    t0, PCB_BLOCKPG(s0)
        beqz  t0, 0f
        li    t3, V_BLOCK + 9841       # or the window's last
0:      bgt   a1, t3, 2f
        li    t0, 0t+000
        csrw  ststatus, t0             # SUA on (resume rewrites ststatus anyway)
        li    t5, V_CONSOLE
1:      bgt   a1, t3, 3f               # stop at the end of the page
        lt    t0, 0(a1)
        beqz  t0, 3f
        sw    t0, 0(t5)
        addi  a1, a1, 1
        j     1b
3:      li    t0, 0
        csrw  ststatus, t0             # SUA off again
        li    a0, 0
        j     sys_return
2:      li    a0, E_RANGE
        j     sys_return

# getc: the next code point, or GETC_NONE once the console is closed. With
# nothing yet, sleep until console input wakes us (devices.s). Code points
# are never negative; the kernel passes on GETC_NONE rather than whatever
# negative value the device chose.
sys_getc:
        li    t0, V_CONSOLE
        lw    a0, CONSOLE_IN(t0)
        bgez  a0, sys_return
        li    t0, CONSOLE_EMPTY
        beq   a0, t0, 1f
        li    a0, GETC_NONE            # closed, or any other negative: none
        j     sys_return
1:      li    t0, ST_GETC
        sw    t0, PCB_STATE(s0)
        li    t0, V_IRQ + 9 * SRC_CONSOLE
        li    t1, 1
        sw    t1, IRQ_ENABLE(t0)       # level-triggered: input already here
        j     schedule                 # interrupts at once

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
        li    t1, ST_ZOMBIE
        beq   t0, t1, 1f               # ended, only its exit code left
        li    t1, ST_RECV
        beq   t0, t1, 2f
        lw    t0, PCB_FULL(s1)
        bnez  t0, 3f
        sw    a2, PCB_MAIL(s1)
        li    t0, 1
        sw    t0, PCB_FULL(s1)
        li    a0, 0
        j     sys_return
1:      li    a0, E_NOPROC
        j     sys_return
2:      sw    a2, PCB_A0(s1)           # its recv returns the value
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        call  wake_one                 # a hart waiting for work can run it
        li    a0, 0
        j     sys_return
3:      li    a0, E_FULL
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
        li    t0, WAIT_EXITED          # a1 already holds the code
        sw    t0, PCB_A0(s0)
        j     release

sys_spawn:
        call  current_pid
        mv    a2, a0                   # the caller is the parent
        call  do_spawn                 # a1: the program
        j     sys_return
        .nocompress
