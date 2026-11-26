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

# spawnw(window, for, args, n): start the program file the caller has
# read into its block windows, its first block in window a1 and the rest
# in the windows after it. Window a1 must hold one: it starts with
# EXEC_MAGIC, so a text file is refused, as is a window the caller does
# not have, and the windows from it on must hold all EXEC_SIZE trytes of
# its image. The new process is the caller's
# child, or with a2 not FOR_SELF the child of process a2, whose call the
# caller holds: so the file server starts a program for the process that
# asked. Its arguments are the a4 trytes at a3 in the parent's memory,
# read there whoever calls, so the file server passes on its client's
# without copying them (ARG_MAX in include/layout.s).
sys_spawnw:
        bltz  a1, 1f
        li    t0, NWIN
        bge   a1, t0, 1f
        li    t0, 3
        mul   t0, a1, t0
        add   t0, t0, s0
        lw    a0, PCB_WINS(t0)         # the window's page
        beqz  a0, 1f
        call  kva
        lw    t0, BLOCK_W0(a0)
        li    t1, EXEC_MAGIC
        bne   t0, t1, 1f
        lw    s5, EXEC_SIZE(a0)        # s5: the image's size
        bltz  s5, 1f
        li    t0, EXEC_MAX
        bgt   s5, t0, 1f
        lw    t0, PCB_A1(s0)           # the whole file in the windows
        li    t1, PAGE
        mul   t0, t0, t1
        li    t1, V_BLOCK - 9841
        add   s3, t0, t1               # s3: the next tryte to look for
        addi  s4, s5, EXEC_HEAD        # s4: trytes still to find
6:      blez  s4, 0f
        mv    a0, s0
        mv    a1, s3
        call  uva
        beqz  a0, 1f
        add   s3, s3, a1
        sub   s4, s4, a1
        j     6b
0:      li    t0, EXEC_LOW             # s5: the pages it takes above the
        sub   s5, s5, t0               # process's own
        bgtz  s5, 0f
        li    s5, 0
        j     6f
0:      li    t0, PAGE - 1
        add   s5, s5, t0
        li    t0, PAGE
        div   s5, s5, t0
6:
        lw    a1, PCB_A2(s0)
        li    t0, FOR_SELF
        beq   a1, t0, 2f
        call  client_of                # its child, if we hold its call
        bltz  a0, sys_return
        lw    a2, PCB_A2(s0)
        j     3f
2:      call  current_pid
        mv    a2, a0                   # the caller is the parent
        mv    s1, s0
3:      mv    s7, s1                   # s7: the parent's record
        lw    t0, PCB_A4(s0)           # the arguments must all be there
        bltz  t0, 4f
        li    t1, ARG_MAX
        bgt   t0, t1, 4f
        beqz  t0, 0f
        mv    a0, s7
        lw    a1, PCB_A3(s0)
        call  uva                      # one page: ARG_MAX is far below one
        beqz  a0, 5f
        lw    t0, PCB_A4(s0)
        blt   a1, t0, 5f
0:      lw    a2, PCB_A2(s0)           # the parent again: uva took it
        li    t0, FOR_SELF
        bne   a2, t0, 0f
        call  current_pid
        mv    a2, a0
0:      li    s6, 1                    # from a program file, s5 pages above
        call  spawn_page
        bltz  a0, sys_return
        j     spawn_args
1:      li    a0, E_NOPROG
        j     sys_return
4:      li    a0, E_INVAL
        j     sys_return
5:      li    a0, E_FAULT
        j     sys_return

# spawn_args: give child a0, just made by spawnw, the arguments spawnw's
# caller named (PCB_A3, PCB_A4) in the memory of the parent whose record
# is s7, checked already: copy them to V_ARGS in the child's page, a
# pointer to each to V_ARGV, and start it with a0 = how many and a1 =
# V_ARGV. The page below V_USER is still all 0, so each string and the
# list end with a 0 whatever the block holds. Returns from spawnw.
spawn_args:
        mv    s2, a0                   # s2: the child
        li    t0, PCB_SIZE
        mul   t0, a0, t0
        la    s1, procs
        add   s1, s1, t0               # s1: its record
        mv    a0, s7
        lw    a1, PCB_A3(s0)
        call  uva                      # a0: where the block is (any, if empty)
        lw    t0, PCB_USERPG(s1)
        li    t1, PAGE
        mul   t0, t0, t1
        li    t1, DMAP + V_ARGV - V_USER
        add   t2, t0, t1               # t2: the next argv word, in the kernel
        li    t1, V_ARGS - V_ARGV
        add   t3, t2, t1               # t3: the next string tryte, in the kernel
        mv    s3, t3                   # s3: argv[0], which names it
        li    t4, V_ARGS               # t4: ... and in the child
        lw    t5, PCB_A4(s0)           # t5: trytes left
        li    a1, 0                    # a1: how many arguments
        li    a2, 1                    # a2: 1 when the next tryte starts one
1:      blez  t5, 3f
        beqz  a2, 2f
        sw    t4, 0(t2)
        addi  t2, t2, 3
        addi  a1, a1, 1
2:      lt    t0, 0(a0)
        st    t0, 0(t3)
        li    a2, 0
        bnez  t0, 0f
        li    a2, 1                    # a 0 ends this one
0:
        addi  a0, a0, 1
        addi  t3, t3, 1
        addi  t4, t4, 1
        addi  t5, t5, -1
        j     1b
3:      sw    a1, PCB_A0(s1)
        li    t0, V_ARGV
        sw    t0, PCB_A1(s1)
        mv    a0, s3                   # its name: argv[0], or none
        li    a1, ARG_MAX
        call  proc_name
        mv    a0, s2
        j     sys_return
        .nocompress
