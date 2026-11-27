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
        li    t0, SYS_IOCALL
        beq   a0, t0, sys_iocall
        li    t0, SYS_CLOSE
        beq   a0, t0, sys_close
        li    t0, SYS_DUP2
        beq   a0, t0, sys_dup2
        li    t0, SYS_GIVE
        beq   a0, t0, sys_give
        li    t0, SYS_FDFLAGS
        beq   a0, t0, sys_fdflags
        li    t0, SYS_CALL
        beq   a0, t0, sys_call_user
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
        li    t0, SYS_LOG
        beq   a0, t0, sys_log
        li    t0, SYS_INFO
        beq   a0, t0, sys_info
        li    t0, SYS_PROC
        beq   a0, t0, sys_proc
        li    t0, SYS_NAME
        beq   a0, t0, sys_name
        li    t0, SYS_SLEEP
        beq   a0, t0, sys_sleep
        li    t0, SYS_NOTIFY
        beq   a0, t0, sys_notify
        li    t0, SYS_ALARM
        beq   a0, t0, sys_alarm
        li    t0, SYS_BRK
        beq   a0, t0, sys_brk
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
# has. The kernel reads it through the direct map (uva, mm.s), so a
# process cannot make it print kernel memory, or fault inside it; the
# string stops at the end of what the process has mapped.
sys_puts:
        mv    s1, a1                   # s1: where the string goes on
        mv    a0, s0
        call  uva
        beqz  a0, 2f
1:      lt    t0, 0(a0)
        beqz  t0, 3f
        call  kout                     # printed and kept in the log
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
        .nocompress
