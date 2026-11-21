# Console input, under the kernel lock. The console's code points pass
# through a buffer of the kernel's, so that Ctrl-C can be seen while
# nobody reads: the kernel reads the console whenever a process waits in
# getc or the console has a foreground process, and Ctrl-C then kills
# that process instead of being read. Otherwise the console is left
# alone, so input queued in advance waits for whoever comes to read it.

        .compress
# getc: the next code point, or GETC_NONE once the console is closed and
# the buffer empty. With nothing yet, sleep until console input wakes us.
# Code points are never negative; the kernel passes on GETC_NONE rather
# than whatever negative value the device chose.
sys_getc:
        li    a1, 1                    # one code point is all it needs
        call  console_drain
        lw    t0, conin_count
        beqz  t0, 1f
        call  conin_pop
        j     2f
1:      lw    t0, conin_closed
        beqz  t0, 3f
        li    a0, GETC_NONE
2:      call  console_arm              # the buffer has room again
        j     sys_return
3:      lw    t0, PCB_KILLED(s0)       # its own Ctrl-C, read just now
        bnez  t0, on_kill
        li    t0, ST_GETC
        sw    t0, PCB_STATE(s0)
        call  console_arm              # level-triggered: input already here
        j     schedule                 # interrupts at once

# console_irq: input has come, or the console has closed. Read what the
# readers waiting in getc need, then hand it to them. Clobbers a0, a1, s1
# and t0..t4.
console_irq:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    a1, 0                    # a1: the readers waiting
        la    t0, procs
1:      lw    t1, PCB_STATE(t0)
        addi  t1, t1, -ST_GETC
        bnez  t1, 2f
        addi  a1, a1, 1
2:      addi  t0, t0, PCB_SIZE
        la    t1, procs + NPROC * PCB_SIZE
        blt   t0, t1, 1b
        call  console_drain
        call  console_serve
        call  console_arm
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# console_drain: move code points from the console into the buffer until
# it holds a1 of them, the buffer is full or the console has nothing.
# Reading no more than readers need leaves input typed ahead in the
# console, where a later Ctrl-C finds the program it was meant for. While
# the console has a foreground process, though, it reads everything, to
# find a Ctrl-C: that kills the process and throws away what was typed
# before it, as a terminal does. Clobbers a0 and t0..t3.
console_drain:
        addi  sp, sp, -3
        sw    ra, 0(sp)
1:      lw    t0, conin_count
        li    t1, CONIN_MAX
        bge   t0, t1, 9f
        lw    t1, foreground
        bgez  t1, 0f                   # look for Ctrl-C in all of it
        bge   t0, a1, 9f               # enough for the readers
0:        li    t0, V_CONSOLE
        lw    a0, CONSOLE_IN(t0)
        bltz  a0, 5f
        li    t0, CTRL_C
        bne   a0, t0, 2f
        lw    t0, foreground
        bltz  t0, 2f                   # nobody to kill: an ordinary code point
        sw    zero, conin_count
        mv    a0, t0
        call  kill_pid
        j     1b
2:      lw    t1, conin_head           # store at head + count, wrapping
        lw    t2, conin_count
        add   t1, t1, t2
        li    t3, CONIN_MAX
        blt   t1, t3, 3f
        sub   t1, t1, t3
3:      li    t3, 3
        mul   t1, t1, t3
        la    t3, conin
        add   t1, t1, t3
        sw    a0, 0(t1)
        addi  t2, t2, 1
        sw    t2, conin_count
        j     1b
5:      li    t0, CONSOLE_EMPTY
        beq   a0, t0, 9f
        li    t0, 1                    # closed, or any other negative
        sw    t0, conin_closed
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# conin_pop: a0 = the oldest code point in the buffer, which the caller
# has seen holds one. Clobbers t0..t2.
conin_pop:
        lw    t0, conin_head
        li    t1, 3
        mul   t1, t0, t1
        la    t2, conin
        add   t1, t1, t2
        lw    a0, 0(t1)
        addi  t0, t0, 1
        li    t1, CONIN_MAX
        blt   t0, t1, 1f
        li    t0, 0
1:      sw    t0, conin_head
        lw    t0, conin_count
        addi  t0, t0, -1
        sw    t0, conin_count
        ret

# console_serve: give each reader waiting in getc, in table order, a code
# point from the buffer while it has any; once it is empty and the
# console closed, GETC_NONE. Clobbers a0, s1 and t0..t3.
console_serve:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    s1, procs
1:      lw    t0, PCB_STATE(s1)
        li    t1, ST_GETC
        bne   t0, t1, 3f
        lw    t0, conin_count
        beqz  t0, 2f
        call  conin_pop
        j     4f
2:      lw    t0, conin_closed
        beqz  t0, 3f                   # nothing for this one yet
        li    a0, GETC_NONE
4:      sw    a0, PCB_A0(s1)
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        call  wake_one
3:      addi  s1, s1, PCB_SIZE
        la    t0, procs + NPROC * PCB_SIZE
        blt   s1, t0, 1b
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# console_arm: let the console interrupt while someone wants its input (a
# reader waits, or a foreground process could be sent Ctrl-C), the
# buffer has room and the console is open; mask it otherwise, since it is
# level-triggered. Clobbers t0..t2.
console_arm:
        li    t2, 0
        lw    t0, conin_closed
        bnez  t0, 8f
        lw    t0, conin_count
        li    t1, CONIN_MAX
        bge   t0, t1, 8f
        li    t2, 1
        lw    t0, foreground
        bgez  t0, 8f
        la    t0, procs
1:      lw    t1, PCB_STATE(t0)
        addi  t1, t1, -ST_GETC
        beqz  t1, 8f
        addi  t0, t0, PCB_SIZE
        la    t1, procs + NPROC * PCB_SIZE
        blt   t0, t1, 1b
        li    t2, 0
8:      li    t0, V_IRQ + 9 * SRC_CONSOLE
        sw    t2, IRQ_ENABLE(t0)
        ret

# foreground(pid): give the console to child pid, so that Ctrl-C kills
# it, or to nobody with NO_FOREGROUND. The kernel takes it back when the
# process ends. A child that has already ended is left out: its number
# could come back as another process's.
sys_foreground:
        li    t0, NO_FOREGROUND
        beq   a1, t0, 1f
        call  find_child
        bltz  a0, sys_return
        lw    t0, PCB_STATE(s1)
        li    t1, ST_ZOMBIE
        beq   t0, t1, 2f
1:      sw    a1, foreground
        call  console_arm
2:      li    a0, 0
        j     sys_return
        .nocompress
