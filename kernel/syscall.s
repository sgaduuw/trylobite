# System calls. The number is in the saved a0, arguments in the saved a1
# and a2; the result goes back into the saved a0.

        .compress
on_syscall:
        csrr  t0, stval                # the instruction after the sys: tpc + 3
        sw    t0, PCB_PC(s0)           # is wrong when the sys is in a bundle
syscall_again:                         # resume runs a call again (ipc.s)
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
        li    t0, SYS_WAIT
        beq   a0, t0, sys_wait
        li    t0, SYS_KILL
        beq   a0, t0, sys_kill
        li    t0, SYS_SPAWNW
        beq   a0, t0, sys_spawnw
        li    t0, SYS_READ
        beq   a0, t0, sys_read
        li    t0, SYS_WRITE
        beq   a0, t0, sys_write
        li    t0, SYS_DESC
        beq   a0, t0, sys_desc
        li    t0, SYS_CALL
        beq   a0, t0, sys_call
        li    t0, SYS_RECEIVE
        beq   a0, t0, sys_receive
        li    t0, SYS_REPLY
        beq   a0, t0, sys_reply
        li    t0, SYS_COPYIN
        beq   a0, t0, sys_copyin
        li    t0, SYS_COPYOUT
        beq   a0, t0, sys_copyout
        li    t0, SYS_REGISTER
        beq   a0, t0, sys_register
        li    t0, SYS_LOOKUP
        beq   a0, t0, sys_lookup
        li    t0, SYS_WINDOW
        beq   a0, t0, sys_window
        li    t0, SYS_DRIVE
        beq   a0, t0, sys_drive
        li    t0, SYS_ARM
        beq   a0, t0, sys_arm
        li    t0, SYS_PHYS
        beq   a0, t0, sys_phys
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

# puts(address): print a 0-terminated string from the caller's memory in
# one go, so preemption cannot split it: its page, or a block window it
# has. The kernel reads it through the direct map (uva, ipc.s), so a
# process cannot make it print kernel memory, or fault inside it; the
# string stops at the end of what the process has mapped.
sys_puts:
        mv    s1, a1                   # s1: where the string goes on
        li    t5, V_CONSOLE
        mv    a0, s0
        call  uva
        beqz  a0, 2f
1:      lt    t0, 0(a0)
        beqz  t0, 3f
        sw    t0, 0(t5)
        addi  s1, s1, 1
        addi  a0, a0, 1
        addi  a1, a1, -1
        bnez  a1, 1b
        mv    a1, s1                   # on into the next page, if mapped
        mv    a0, s0
        call  uva
        bnez  a0, 1b
3:      li    a0, 0
        j     sys_return
2:      li    a0, E_RANGE
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

# spawnw(window, for): start the program file whose first block the
# caller has read into block window a1. The window must hold one: it
# starts with EXEC_MAGIC, so a text file is refused, as is a window the
# caller does not have. The new process is the caller's child, or with
# a2 not FOR_SELF the child of process a2, whose call the caller holds:
# so the file server starts a program for the process that asked.
sys_spawnw:
        bltz  a1, 1f
        li    t0, NWIN
        bge   a1, t0, 1f
        li    t0, 3
        mul   t0, a1, t0
        add   t0, t0, s0
        lw    s5, PCB_WINS(t0)         # s5: the window's page
        beqz  s5, 1f
        mv    a0, s5
        call  kva
        lw    t0, BLOCK_W0(a0)
        li    t1, EXEC_MAGIC
        bne   t0, t1, 1f
        lw    a1, PCB_A2(s0)
        li    t0, FOR_SELF
        beq   a1, t0, 2f
        call  client_of                # its child, if we hold its call
        bltz  a0, sys_return
        lw    a2, PCB_A2(s0)
        j     3f
2:      call  current_pid
        mv    a2, a0                   # the caller is the parent
3:      li    s6, 1                    # from a program file
        call  spawn_page
        j     sys_return
1:      li    a0, E_NOPROG
        j     sys_return
        .nocompress
