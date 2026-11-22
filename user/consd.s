# The console server: the console's driver, as a process. It drives
# source SRC_CONSOLE (SYS_DRIVE), so the console's registers are mapped
# into it and its input interrupts come to it as notices, and registers
# as "console", protocol CONSOLE_PROTOCOL, before it takes its first
# call. Clients find it by that name (SYS_LOOKUP); the shell is the usual
# one. The kernel still prints its own messages to the console's output
# directly, and SYS_PUTC and SYS_PUTS with them: that is its log.
#
# A console call is a SYS_CALL with CN_GETC, CN_WRITE or CN_FOREGROUND in
# a2 and the arguments in a3 and a4 (include/layout.s). It also answers
# descriptor calls, IO_READ and IO_WRITE, on its one handle,
# CONSOLE_HANDLE: the shell points standard input, output and error there
# (SYS_DESC), so programs reach it with SYS_READ and SYS_WRITE.
#
# Input passes through a buffer of the server's, so that Ctrl-C can be
# seen while nobody reads: the server reads the console only while a
# process waits in getc or the console has a foreground process, and a
# Ctrl-C then kills that process instead of being read. Otherwise the
# console is left alone, so input typed ahead waits in it for whoever
# comes to read it, and a Ctrl-C typed ahead finds the program it was
# meant for. A reader's call is held, unanswered, until there is a code
# point for it (cn_readers), as the kernel held a reader in getc before.
#
# The foreground is the server's: the shell names each program it runs
# with CN_FOREGROUND, and the server ends it at Ctrl-C with SYS_KILL on
# the shell's behalf, which the kernel allows a driver. A process that
# is not the caller's child is not refused when named, but the kill then
# fails, and Ctrl-C is read as an ordinary code point.
#
# Not a program on its own: a build includes it in a program's section.
# Its labels all start with cn_, since it shares the build's symbols.

        .compress
        .gp   USER_GP

        .equ  CN_REGS, V_DEVICE + PAGE * (SRC_CONSOLE - 1)  # its registers
        .equ  CN_MAX, 81               # code points held for readers
        .equ  CN_CHUNK, 243            # trytes a write copies in, or a read
                                       # gives, at a time
        .equ  CN_GETTER, 1             # cn_readers: waiting in getc,
        .equ  CN_READER, 2             # or in a descriptor's read

cn_main:
        li    a0, SYS_DRIVE
        li    a1, SRC_CONSOLE
        sys
        bltz  a0, cn_quit
        li    a0, SYS_REGISTER
        la    a1, cn_name
        li    a2, CONSOLE_PROTOCOL
        sys
        bgez  a0, cn_wait
cn_quit:                               # a0: why it cannot serve
        mv    a1, a0
        li    a0, SYS_EXIT
        sys

cn_wait:
        li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, cn_notice
        mv    s0, a0                   # s0: the caller
        li    t0, CN_GETC
        beq   a1, t0, cn_getc
        li    t0, CN_WRITE
        beq   a1, t0, cn_write
        li    t0, CN_FOREGROUND
        beq   a1, t0, cn_fground
        li    t0, IO_READ
        beq   a1, t0, cn_ioread
        li    t0, IO_WRITE
        beq   a1, t0, cn_iowrite
cn_inval:
        li    a2, E_INVAL

# cn_answer: reply a2 to process s0, and go back to waiting.
cn_answer:
        li    a0, SYS_REPLY
        mv    a1, s0
        sys
        j     cn_wait

cn_notice:
        li    t0, NOTE_IRQ             # input has come, or the console
        beq   a1, t0, cn_serve         # has closed
        li    t0, 3                    # NOTE_ENDED: a reader no longer
        mul   t0, a2, t0
        la    t1, cn_readers
        add   t1, t1, t0
        sw    zero, 0(t1)
        lw    t0, cn_fg                # and the console goes back to
        beq   t0, a2, 1f               # nobody when its foreground ends,
        lw    t0, cn_fgfor             # or the process that named it,
        bne   t0, a2, cn_wait          # whose authority a kill uses
1:      li    t0, NO_FOREGROUND
        sw    t0, cn_fg
        j     cn_wait

# getc(): hold the call until there is a code point for it.
cn_getc:
        li    t0, CN_GETTER
        j     cn_hold

# A descriptor's read(handle, buffer, n): hold the call until there is
# input for it, then give it what the buffer holds, up to n code points,
# one to a tryte. 0 at the end of input, or at once for n 0.
cn_ioread:
        bnez  a2, cn_badf              # the console's one handle
        bltz  a4, cn_inval
        bnez  a4, 1f
        li    a2, 0
        j     cn_answer
1:      li    t0, 3
        mul   t0, s0, t0
        la    t1, cn_rbufs
        add   t1, t1, t0
        sw    a3, 0(t1)
        la    t1, cn_rns
        add   t1, t1, t0
        sw    a4, 0(t1)
        li    t0, CN_READER

# cn_hold: keep process s0's call, of kind t0, until there is input.
cn_hold:
        li    t1, 3
        mul   t1, s0, t1
        la    t2, cn_readers
        add   t2, t2, t1
        sw    t0, 0(t2)
        j     cn_serve

# A descriptor's write(handle, buffer, n): as CN_WRITE.
cn_iowrite:
        bnez  a2, cn_badf
        mv    a2, a3
        mv    a3, a4
        j     cn_write
cn_badf:
        li    a2, E_BADF
        j     cn_answer

# write(buffer, n): copy the caller's trytes in, a chunk at a time, and
# print them. A fault partway leaves what came before it printed.
cn_write:
        bltz  a3, cn_inval
        mv    s1, a2                   # s1: where the rest starts
        mv    s2, a3                   # s2: how much is left
        mv    s3, a3                   # s3: how much was asked
1:      beqz  s2, 4f
        mv    s4, s2                   # s4: this chunk
        li    t0, CN_CHUNK
        ble   s4, t0, 2f
        mv    s4, t0
2:      li    a0, SYS_COPYIN
        mv    a1, s0
        mv    a2, s1
        la    a3, cn_out
        mv    a4, s4
        sys
        bnez  a0, 5f
        la    t0, cn_out
        add   t1, t0, s4
        li    t2, CN_REGS
3:      lt    t3, 0(t0)
        sw    t3, 0(t2)
        addi  t0, t0, 1
        bne   t0, t1, 3b
        add   s1, s1, s4
        sub   s2, s2, s4
        j     1b
4:      mv    a2, s3
        j     cn_answer
5:      li    a2, E_FAULT
        j     cn_answer

# foreground(pid): give the console to pid, the caller's child, or to
# nobody; then look at the console, which may now hold a Ctrl-C for it.
cn_fground:
        li    t0, NO_FOREGROUND
        beq   a2, t0, 1f
        bltz  a2, cn_inval
        li    t0, NPROC
        bge   a2, t0, cn_inval
        sw    s0, cn_fgfor
1:      sw    a2, cn_fg
        li    a0, SYS_REPLY
        mv    a1, s0
        li    a2, 0
        sys
        lw    t0, cn_fg                # a Ctrl-C typed ahead, kept since it
        bltz  t0, cn_serve             # ended nothing then, is for this one:
        li    s6, 0                    # s6: how far into the buffer
1:      lw    t0, cn_count
        bge   s6, t0, cn_serve
        lw    t1, cn_head
        add   t1, t1, s6
        li    t2, CN_MAX
        blt   t1, t2, 2f
        sub   t1, t1, t2
2:      mv    s7, t1                   # s7: where in cn_buf
        li    t2, 3
        mul   t1, t1, t2
        la    t2, cn_buf
        add   t1, t1, t2
        lw    t1, 0(t1)
        li    t2, CTRL_C
        beq   t1, t2, 3f
        addi  s6, s6, 1
        j     1b
3:      call  cn_kill                  # kill it, and throw away what was
        bnez  a0, cn_serve             # typed before the Ctrl-C
        addi  s7, s7, 1
        li    t0, CN_MAX
        blt   s7, t0, 4f
        li    s7, 0
4:      sw    s7, cn_head
        lw    t0, cn_count
        sub   t0, t0, s6
        addi  t0, t0, -1
        sw    t0, cn_count

# cn_serve: read what the readers need from the console, and everything
# while it has a foreground process; answer every reader there is a code
# point for; let the console interrupt while it is still wanted. Then go
# back to waiting.
cn_serve:
        li    s5, 0                    # s5: the readers waiting
        la    t0, cn_readers
        li    t1, NPROC
1:      lw    t2, 0(t0)
        beqz  t2, 2f
        addi  s5, s5, 1
2:      addi  t0, t0, 3
        addi  t1, t1, -1
        bnez  t1, 1b

# cn_drain: move code points from the console into the buffer until it
# holds what the readers need, the buffer is full or the console has
# nothing. Reading no more than readers need leaves input typed ahead in
# the console, where a later Ctrl-C finds the program it was meant for.
# While the console has a foreground process, though, it reads
# everything, to find a Ctrl-C: that kills the process and throws away
# what was typed before it, as a terminal does.
cn_drain:
        lw    t0, cn_closed
        bnez  t0, cn_give
        lw    t0, cn_count
        li    t1, CN_MAX
        bge   t0, t1, cn_give
        lw    t1, cn_fg
        bgez  t1, 1f                   # look for Ctrl-C in all of it
        bge   t0, s5, cn_give          # enough for the readers
1:      li    t0, CN_REGS
        lw    a0, CONSOLE_IN(t0)
        bltz  a0, 4f
        li    t0, CTRL_C
        bne   a0, t0, 2f
        lw    t1, cn_fg
        bltz  t1, 2f                   # nobody to kill: an ordinary code point
        call  cn_kill
        bnez  a0, 3f
        sw    zero, cn_count
        j     cn_serve                 # one reader fewer, maybe
3:      li    a0, CTRL_C               # it ended nothing: kept, for the next
2:      call  cn_push                  # foreground process or a reader
        j     cn_drain
4:      li    t0, CONSOLE_EMPTY
        beq   a0, t0, cn_give
        li    t0, 1                    # closed, or any other negative
        sw    t0, cn_closed

# cn_give: give each reader, in process order, input from the buffer
# while it has any: getc one code point, read up to its n. Once the
# buffer is empty and the console closed, getc gets GETC_NONE and read 0.
# A reader that has gone meanwhile gives what it took back.
cn_give:
        li    s6, 0                    # s6: the process
1:      li    t0, 3
        mul   s7, s6, t0
        la    t0, cn_readers
        add   s7, s7, t0               # s7: its entry
        lw    s3, 0(s7)                # s3: its kind of call
        beqz  s3, 4f
        li    s8, 0                    # s8: how many code points it took
        lw    t0, cn_count
        beqz  t0, 2f
        li    t1, CN_READER
        beq   s3, t1, 5f
        call  cn_pop
        mv    a2, a0
        li    s8, 1
        j     3f
2:      lw    t0, cn_closed
        beqz  t0, 4f                   # nothing for this one yet
        li    a2, GETC_NONE
        li    t1, CN_READER
        bne   s3, t1, 3f
        li    a2, 0                    # read's end of input
3:      sw    zero, 0(s7)
        li    a0, SYS_REPLY
        mv    a1, s6
        sys
        bgez  a0, 4f
6:      beqz  s8, 4f                   # it has gone: put back what it took
        call  cn_unpop
        addi  s8, s8, -1
        j     6b
4:      addi  s6, s6, 1
        li    t0, NPROC
        blt   s6, t0, 1b
        j     cn_arm

# A read: up to n code points into cn_in, then out to its buffer.
5:      la    t0, cn_readers
        sub   t1, s7, t0               # t1: its entries' offset
        la    t0, cn_rns
        add   t0, t0, t1
        lw    s4, 0(t0)                # s4: n, or as much as cn_in holds
        li    t0, CN_CHUNK
        ble   s4, t0, 9f
        mv    s4, t0
9:
        la    t0, cn_rbufs
        add   t0, t0, t1
        lw    s2, 0(t0)                # s2: its buffer
7:      lw    t0, cn_count
        beqz  t0, 8f
        beq   s8, s4, 8f
        call  cn_pop
        la    t0, cn_in
        add   t0, t0, s8
        st    a0, 0(t0)
        addi  s8, s8, 1
        j     7b
8:      li    a0, SYS_COPYOUT
        mv    a1, s6
        la    a2, cn_in
        mv    a3, s2
        mv    a4, s8
        sys
        mv    a2, s8
        beqz  a0, 3b
        sw    zero, 0(s7)              # a buffer it does not have
        li    a0, SYS_REPLY
        mv    a1, s6
        li    a2, E_FAULT
        sys
        j     6b
        li    t0, NPROC
        blt   s6, t0, 1b

# cn_arm: let the console interrupt while someone wants its input (a
# reader waits, or a foreground process could be sent Ctrl-C), the
# buffer has room and the console is open. Each interrupt masks it again.
cn_arm:
        lw    t0, cn_closed
        bnez  t0, cn_wait
        lw    t0, cn_count
        li    t1, CN_MAX
        bge   t0, t1, cn_wait
        lw    t0, cn_fg
        bgez  t0, 6f
        la    t0, cn_readers
        li    t1, NPROC
5:      lw    t2, 0(t0)
        bnez  t2, 6f
        addi  t0, t0, 3
        addi  t1, t1, -1
        bnez  t1, 5b
        j     cn_wait
6:      li    a0, SYS_ARM
        li    a1, SRC_CONSOLE
        sys
        j     cn_wait

# cn_kill: Ctrl-C: end the foreground process, for the process that
# named it; the console is nobody's after. a0 = 0 if it was ended, else
# KILL_ENDED or why not, and the Ctrl-C ended nothing. Clobbers a1, a2,
# t0, t1.
cn_kill:
        lw    a1, cn_fg
        li    t0, NO_FOREGROUND
        sw    t0, cn_fg
        li    a0, SYS_KILL
        lw    a2, cn_fgfor
        sys
        bnez  a0, 1f
        li    t0, 3                    # it reads nothing more
        mul   t0, a1, t0
        la    t1, cn_readers
        add   t1, t1, t0
        sw    zero, 0(t1)
1:      ret

# cn_push: put code point a0 at the buffer's end, which has room.
# Clobbers t1..t3.
cn_push:
        lw    t1, cn_head              # store at head + count, wrapping
        lw    t2, cn_count
        add   t1, t1, t2
        li    t3, CN_MAX
        blt   t1, t3, 1f
        sub   t1, t1, t3
1:      li    t3, 3
        mul   t1, t1, t3
        la    t3, cn_buf
        add   t1, t1, t3
        sw    a0, 0(t1)
        addi  t2, t2, 1
        sw    t2, cn_count
        ret

# cn_pop: a0 = the oldest code point in the buffer, which holds one.
# Clobbers t0..t2.
cn_pop:
        lw    t0, cn_head
        li    t1, 3
        mul   t1, t0, t1
        la    t2, cn_buf
        add   t1, t1, t2
        lw    a0, 0(t1)
        addi  t0, t0, 1
        li    t1, CN_MAX
        blt   t0, t1, 1f
        li    t0, 0
1:      sw    t0, cn_head
        lw    t0, cn_count
        addi  t0, t0, -1
        sw    t0, cn_count
        ret

# cn_unpop: put back the code point cn_pop took last. Clobbers t0, t1.
cn_unpop:
        lw    t0, cn_head
        addi  t0, t0, -1
        bgez  t0, 1f
        li    t0, CN_MAX - 1
1:      sw    t0, cn_head
        lw    t0, cn_count
        addi  t0, t0, 1
        sw    t0, cn_count
        ret

cn_fg:  .word NO_FOREGROUND            # the process Ctrl-C kills,
cn_fgfor: .word 0                      # and the one that named it
cn_head: .word 0                       # the buffer's oldest code point
cn_count: .word 0                      # how many it holds
cn_closed: .word 0                     # 1 once the console said it is closed
cn_readers: .words NPROC               # each process's waiting call: CN_GETTER,
                                       # CN_READER, or 0 for none;
cn_rbufs: .words NPROC                 # a read's buffer
cn_rns: .words NPROC                   # and how much it wants
cn_buf: .words CN_MAX                  # console input, a ring
cn_out: .zero CN_CHUNK                 # what a write prints
cn_in:  .zero CN_CHUNK                 # what a read gives
cn_name: .string "console"
        .nocompress
