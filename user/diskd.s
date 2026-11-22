# The disk server: the block device's driver, as a process. It drives
# source SRC_DISK (SYS_DRIVE), so the device's registers are mapped into
# it and its interrupts come to it as notices, and registers as "disk",
# protocol DISK_PROTOCOL, before it takes its first call. Clients find it
# by that name (SYS_LOOKUP); the file server is the usual one.
#
# A disk call is a SYS_CALL with DK_READ or DK_WRITE in a2, the block in
# a3 and the centre of a page-sized buffer in a4 (include/layout.s). The
# disk moves one block at a time, through the server's block window 0:
# a write copies the caller's buffer in, then gives the disk the command;
# a read gives the command, then copies the block out. The server arms
# the disk's interrupt after each command and goes back to receive, so it
# takes calls while the disk works; each waits in dk_ops, one per process
# (a process has one call at a time), and the next is started, in process
# order after the last, when the one in flight is done.
#
# The disk is told once where its list is: one word, dk_list, the
# physical page of window 0. Every command moves one block (COUNT, 1 at
# reset), so only BLOCK and COMMAND change.
#
# Not a program on its own: a build includes it in a program's section.
# Its labels all start with dk_, since it shares the build's symbols.

        .compress
        .gp   USER_GP

        .equ  DK_REGS, V_DEVICE + PAGE * (SRC_DISK - 1)   # the disk's registers
        .equ  DK_IDLE, -1              # dk_cur with no command in flight

dk_main:
        li    a0, SYS_NAME             # for ps: a program of the image
        la    a1, dk_myname            # has no argv[0] to name it
        sys
        li    a0, SYS_DRIVE
        li    a1, SRC_DISK
        sys
        bltz  a0, dk_quit
        li    a0, SYS_WINDOW           # where blocks land
        li    a1, 0
        sys
        bltz  a0, dk_quit
        li    a0, SYS_PHYS
        li    a1, V_BLOCK
        sys
        bltz  a0, dk_quit
        li    t0, PAGE
        div   a0, a0, t0               # the window's centre: its page number
        sw    a0, dk_list
        li    a0, SYS_PHYS
        la    a1, dk_list
        sys
        bltz  a0, dk_quit
        li    t0, DK_REGS
        sw    a0, DISK_LIST(t0)
        li    a0, SYS_REGISTER
        la    a1, dk_name
        li    a2, DISK_PROTOCOL
        sys
        bgez  a0, dk_wait
dk_quit:                               # a0: why it cannot serve
        mv    a1, a0
        li    a0, SYS_EXIT
        sys

dk_wait:
        li    sp, USER_SP
        li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, dk_notice
        mv    s0, a0                   # s0: the caller
        li    a5, E_INVAL
        li    t0, DK_READ
        beq   a1, t0, 1f
        li    t0, DK_WRITE
        bne   a1, t0, dk_answer
1:      li    a5, E_NOBLOCK
        bltz  a2, dk_answer
        li    t0, DK_REGS
        lw    t0, DISK_BLOCKS(t0)
        bge   a2, t0, dk_answer        # past the end, or no disk at all
        li    t0, 3                    # keep it until the disk is free
        mul   t1, s0, t0
        addi  a1, a1, 1                # 0 there means no call
        la    t0, dk_ops
        add   t0, t0, t1
        sw    a1, 0(t0)
        la    t0, dk_blocks
        add   t0, t0, t1
        sw    a2, 0(t0)
        la    t0, dk_bufs
        add   t0, t0, t1
        sw    a3, 0(t0)
        lw    t0, dk_cur
        bltz  t0, dk_next              # idle: start it now
        j     dk_wait

# dk_answer: reply a5 to process s0, and go back to waiting.
dk_answer:
        li    a0, SYS_REPLY
        mv    a1, s0
        mv    a2, a5
        sys
        j     dk_wait

dk_notice:
        li    t0, NOTE_IRQ
        beq   a1, t0, dk_done
        li    t0, 3                    # NOTE_ENDED: its waiting call
        mul   t0, a2, t0               # failed with it
        la    t1, dk_ops
        add   t1, t1, t0
        sw    zero, 0(t1)
        lw    t0, dk_cur
        bne   t0, a2, dk_wait
        li    t0, 1                    # the command in flight is nobody's
        sw    t0, dk_gone              # now, and the number may come back
        j     dk_wait

# dk_done: the command in flight has finished. Tell its caller how it
# went, copying a block it read out to it, then start the next.
dk_done:
        lw    s0, dk_cur
        bltz  s0, dk_wait              # nothing was asked of it
        li    t0, DK_REGS
        lw    t1, DISK_STATUS(t0)
        sw    zero, DISK_ACK(t0)
        li    t0, DK_IDLE
        sw    t0, dk_cur
        lw    t0, dk_gone
        bnez  t0, dk_next
        li    a5, E_IO
        li    t0, BLOCK_FAILED
        beq   t1, t0, 1f
        li    a5, 0
        lw    t0, dk_op
        li    t1, DK_READ
        bne   t0, t1, 1f
        li    a0, SYS_COPYOUT
        mv    a1, s0
        li    a2, V_BLOCK + BLOCK_T0
        lw    a3, dk_buf
        addi  a3, a3, BLOCK_T0
        li    a4, PAGE
        sys
        beqz  a0, 1f
        li    a5, E_FAULT
1:      li    a0, SYS_REPLY
        mv    a1, s0
        mv    a2, a5
        sys

# dk_next: start the next waiting call, after the last one started, if
# any is waiting.
dk_next:
        lw    s0, dk_last
        li    s1, NPROC                # s1: how many are left to look at
1:      addi  s0, s0, 1
        li    t0, NPROC
        blt   s0, t0, 2f
        li    s0, 0
2:      li    t0, 3
        mul   s2, s0, t0               # s2: its entries' offset
        la    t0, dk_ops
        add   t0, t0, s2
        lw    t1, 0(t0)
        bnez  t1, dk_start
        addi  s1, s1, -1
        bnez  s1, 1b
        j     dk_wait

# dk_start: give the disk process s0's call, its entry in dk_ops at t0
# and its op plus 1 in t1. A write first copies the caller's buffer in.
dk_start:
        sw    zero, 0(t0)
        sw    s0, dk_last
        addi  t1, t1, -1
        sw    t1, dk_op
        la    t0, dk_blocks
        add   t0, t0, s2
        lw    s3, 0(t0)                # s3: the block
        la    t0, dk_bufs
        add   t0, t0, s2
        lw    t0, 0(t0)
        sw    t0, dk_buf
        li    s4, BLOCK_READ           # s4: the command
        li    t2, DK_READ
        beq   t1, t2, 3f
        li    s4, BLOCK_WRITE
        li    a0, SYS_COPYIN
        mv    a1, s0
        addi  a2, t0, BLOCK_T0
        li    a3, V_BLOCK + BLOCK_T0
        li    a4, PAGE
        sys
        beqz  a0, 3f
        li    a0, SYS_REPLY            # nothing to write: try the next
        mv    a1, s0
        li    a2, E_FAULT
        sys
        j     dk_next
3:      sw    s0, dk_cur
        sw    zero, dk_gone
        li    t0, DK_REGS
        sw    s3, DISK_BLOCK(t0)
        sw    s4, DISK_COMMAND(t0)
        li    a0, SYS_ARM              # after the command: the interrupt
        li    a1, SRC_DISK             # is level-triggered, so one that
        sys                            # came first is not lost
        j     dk_wait

dk_cur: .word DK_IDLE                  # whose command is in flight
dk_gone: .word 0                       # 1 if that process has ended since
dk_op:  .word 0                        # ... its operation,
dk_buf: .word 0                        # and its buffer
dk_last: .word NPROC - 1               # whose call was started last
dk_list: .word 0                       # the disk's list: window 0's page
dk_ops: .words NPROC                   # each process's waiting call: its
dk_blocks: .words NPROC                # operation plus 1 (0 for none), the
dk_bufs: .words NPROC                  # block, and the buffer
dk_name: .string "disk"
dk_myname: .string "diskd"
        .nocompress
