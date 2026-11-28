# The pipe server: pipes, as a process. It registers as "pipe", protocol
# PIPE_PROTOCOL, before it takes its first call; clients find it by that
# name (SYS_LOOKUP).
#
# PP_PIPE gives the caller two descriptors (SYS_GIVE): a pipe's read end
# and its write end. What is written on one is read from the other, in
# order, through a buffer of PP_SIZE trytes here. Both ends are handles of
# this server, pipe k's read end 2k and its write end 2k + 1, and reach it
# as descriptor calls, IO_READ and IO_WRITE, from whoever holds a copy:
# the shell starts each program of a pipeline with one end as its
# standard input or output.
#
# A read waits while the pipe is empty and a write end is still open,
# then gives what there is, up to n; once every write end has closed it
# gives 0, the end. A write waits until all n trytes have gone into the
# buffer, so a writer never sees a partial count, and fails with E_PIPE
# once every read end has closed: nobody would read it. The writer is sent
# SIGPIPE then too, as Unix sends it, which ends it unless it ignores or
# catches the signal. The kernel says
# when the last descriptor for an end goes (NOTE_CLOSED); a pipe whose
# two ends are gone is free again.
#
# A waiting call is held, unanswered, one per process (pp_kinds), as the
# console server holds a reader. After each call or notice the server
# moves what it can for every held call, again until nothing moves.
#
# Not a program on its own: a build includes it in a program's section.
# Its labels all start with pp_, since it shares the build's symbols.

        .compress
        .gp   USER_GP

        .equ  PP_NPIPE, NHANDLE / 2    # pipes, two handles each
        .equ  PP_SIZE, 729             # trytes a pipe holds
        .equ  PP_CHUNK, 243            # trytes moved at a time
        .equ  PP_READER, 1             # pp_kinds: a held read,
        .equ  PP_WRITER, 2             # or a held write

pp_main:
        li    a0, SYS_NAME             # for ps: a program of the image
        la    a1, pp_myname            # has no argv[0] to name it
        sys
        li    a0, SYS_REGISTER
        la    a1, pp_name
        li    a2, PIPE_PROTOCOL
        sys
        bgez  a0, pp_wait
        mv    a1, a0                   # why it cannot serve
        li    a0, SYS_EXIT
        sys

pp_wait:
        li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, pp_notice
        mv    s0, a0                   # s0: the caller
        li    t0, PP_PIPE
        beq   a1, t0, pp_pipe
        li    t0, IO_READ
        beq   a1, t0, pp_read
        li    t0, IO_WRITE
        beq   a1, t0, pp_write
pp_inval:
        li    a2, E_INVAL

# pp_answer: reply a2 to process s0, and go back to waiting.
pp_answer:
        li    a0, SYS_REPLY
        mv    a1, s0
        sys
        j     pp_wait

# pipe(): a free pipe, its read end and then its write end given to the
# caller: a0 = the read end's descriptor, a1 the write end's. If only the
# read end could be given, E_MFILE comes with that descriptor in a1, for
# the caller to close.
pp_pipe:
        li    s1, 0                    # s1: the pipe
1:      li    t0, 3
        mul   s2, s1, t0               # s2: its entries' offset
        la    t0, pp_used
        add   t0, t0, s2
        lw    t1, 0(t0)
        beqz  t1, 2f
        addi  s1, s1, 1
        li    t0, PP_NPIPE
        blt   s1, t0, 1b
        li    a2, E_NOSPC
        j     pp_answer
2:      li    t1, 1
        sw    t1, 0(t0)
        la    t0, pp_heads
        add   t0, t0, s2
        sw    zero, 0(t0)
        la    t0, pp_counts
        add   t0, t0, s2
        sw    zero, 0(t0)
        la    t0, pp_rgone
        add   t0, t0, s2
        sw    zero, 0(t0)
        la    t0, pp_wgone
        add   t0, t0, s2
        sw    zero, 0(t0)
        li    a0, SYS_GIVE
        mv    a1, s0
        add   a2, s1, s1               # the read end
        sys
        bgez  a0, 3f
        la    t0, pp_used              # none: the pipe was never seen
        add   t0, t0, s2
        sw    zero, 0(t0)
        mv    a2, a0
        j     pp_answer
3:      mv    s3, a0                   # s3: the read end's descriptor
        li    a0, SYS_GIVE
        mv    a1, s0
        add   a2, s1, s1
        addi  a2, a2, 1                # the write end
        sys
        bgez  a0, 4f
        la    t0, pp_wgone             # nobody will write: it goes once
        add   t0, t0, s2               # the read end closes
        li    t1, 1
        sw    t1, 0(t0)
        mv    a2, a0
        mv    a3, s3
        li    a0, SYS_REPLY
        mv    a1, s0
        sys
        j     pp_wait
4:      mv    a3, a0
        mv    a2, s3
        li    a0, SYS_REPLY
        mv    a1, s0
        sys
        j     pp_wait

# A descriptor's read(handle, buffer, n), on a read end: hold it.
pp_read:
        li    t0, 2
        rem   t1, a2, t0
        bnez  t1, pp_badf              # a write end
        li    s4, PP_READER
        j     1f
# A descriptor's write(handle, buffer, n), on a write end: hold it, or
# E_PIPE at once if nobody can read it.
pp_write:
        li    t0, 2
        rem   t1, a2, t0
        beqz  t1, pp_badf              # a read end
        li    s4, PP_WRITER
1:      bltz  a4, pp_inval
        bnez  a4, 2f
        li    a2, 0                    # nothing asked: nothing to wait for
        j     pp_answer
2:      li    t0, 2
        div   s1, a2, t0               # s1: the pipe
        li    t0, 3
        mul   t0, s0, t0               # t0: the caller's entries' offset
        la    t1, pp_pipes
        add   t1, t1, t0
        sw    s1, 0(t1)
        la    t1, pp_bufs
        add   t1, t1, t0
        sw    a3, 0(t1)
        la    t1, pp_ns
        add   t1, t1, t0
        sw    a4, 0(t1)
        la    t1, pp_dones
        add   t1, t1, t0
        sw    zero, 0(t1)
        la    t1, pp_kinds
        add   t1, t1, t0
        sw    s4, 0(t1)
        j     pp_serve
pp_badf:
        li    a2, E_BADF
        j     pp_answer

# An end of a pipe has no descriptor left: a pipe with neither is free.
# A process ended: drop the call it had held.
pp_notice:
        li    t0, NOTE_CLOSED
        bne   a1, t0, 3f
        li    t0, 2
        div   s1, a2, t0               # s1: the pipe
        rem   t1, a2, t0               # t1: 0 the read end, 1 the write end
        li    t0, 3
        mul   s2, s1, t0
        la    t0, pp_rgone
        beqz  t1, 1f
        la    t0, pp_wgone
1:      add   t0, t0, s2
        li    t1, 1
        sw    t1, 0(t0)
        la    t0, pp_rgone
        add   t0, t0, s2
        lw    t1, 0(t0)
        la    t0, pp_wgone
        add   t0, t0, s2
        lw    t2, 0(t0)
        add   t1, t1, t2
        li    t0, 2
        blt   t1, t0, pp_serve         # one is left: held calls may finish
        la    t0, pp_used
        add   t0, t0, s2
        sw    zero, 0(t0)
        j     pp_wait
3:      li    t0, NOTE_ENDED
        bne   a1, t0, pp_wait
        li    t0, 3
        mul   t0, a2, t0
        la    t1, pp_kinds
        add   t1, t1, t0
        sw    zero, 0(t1)
        j     pp_wait

# pp_serve: for each process with a held call, in process order, move
# what can be moved, answering each call that is done; then again, while
# anything moved. Then go back to waiting.
pp_serve:
        li    s5, 0                    # s5: 1 once something moved
        li    s6, 0                    # s6: the process
1:      li    t0, 3
        mul   s7, s6, t0               # s7: its entries' offset
        la    t0, pp_kinds
        add   t0, t0, s7
        lw    s4, 0(t0)                # s4: its kind of call
        beqz  s4, 8f
        la    t0, pp_pipes
        add   t0, t0, s7
        lw    s1, 0(t0)                # s1: the pipe
        li    t0, 3
        mul   s2, s1, t0               # s2: the pipe's entries' offset
        la    t0, pp_counts
        add   t0, t0, s2
        lw    s3, 0(t0)                # s3: what it holds
        li    t0, PP_WRITER
        beq   s4, t0, 5f

        bnez  s3, 2f                   # a read: something to give,
        la    t0, pp_wgone             # or the end, or nothing yet
        add   t0, t0, s2
        lw    t0, 0(t0)
        beqz  t0, 8f
        li    a2, 0
        j     7f
2:      la    t0, pp_ns
        add   t0, t0, s7
        lw    s8, 0(t0)                # s8: how much: n,
        ble   s8, s3, 3f
        mv    s8, s3                   # or what it holds,
3:      li    t0, PP_CHUNK
        ble   s8, t0, 4f
        mv    s8, t0                   # or a chunk
4:      call  pp_take                  # into pp_tmp
        li    a0, SYS_COPYOUT
        mv    a1, s6
        la    a2, pp_tmp
        la    t0, pp_bufs
        add   t0, t0, s7
        lw    a3, 0(t0)
        mv    a4, s8
        sys
        li    s5, 1
        mv    a2, s8
        beqz  a0, 7f
        li    a2, E_FAULT              # a buffer it does not have
        j     7f

5:      la    t0, pp_rgone             # a write: nobody to read it,
        add   t0, t0, s2
        lw    t0, 0(t0)
        beqz  t0, 6f
        li    a0, SYS_KILL             # and SIGPIPE, which ends it unless
        mv    a1, s6                   # it ignores or catches it
        li    a2, KILL_ANY
        li    a3, SIGPIPE
        sys
        li    a2, E_PIPE
        j     7f
6:      li    t0, PP_SIZE              # or room for some of the rest
        sub   t1, t0, s3               # t1: the room
        beqz  t1, 8f
        la    t0, pp_ns
        add   t0, t0, s7
        lw    s8, 0(t0)
        la    t0, pp_dones
        add   t0, t0, s7
        lw    t2, 0(t0)                # t2: written so far
        sub   s8, s8, t2               # s8: how much: the rest,
        ble   s8, t1, 9f
        mv    s8, t1                   # or the room,
9:      li    t0, PP_CHUNK
        ble   s8, t0, 9f
        mv    s8, t0                   # or a chunk
9:      li    a0, SYS_COPYIN
        mv    a1, s6
        la    t0, pp_bufs
        add   t0, t0, s7
        lw    a2, 0(t0)
        add   a2, a2, t2
        la    a3, pp_tmp
        mv    a4, s8
        sys
        li    s5, 1
        li    a2, E_FAULT
        bnez  a0, 7f
        call  pp_put                   # from pp_tmp
        la    t0, pp_dones
        add   t0, t0, s7
        lw    t1, 0(t0)
        add   t1, t1, s8
        sw    t1, 0(t0)
        la    t0, pp_ns
        add   t0, t0, s7
        lw    a2, 0(t0)
        bne   t1, a2, 8f               # not all of it yet

7:      la    t0, pp_kinds             # answer it with a2
        add   t0, t0, s7
        sw    zero, 0(t0)
        li    a0, SYS_REPLY
        mv    a1, s6
        sys
8:      addi  s6, s6, 1
        li    t0, NPROC
        blt   s6, t0, 1b
        bnez  s5, pp_serve
        j     pp_wait

# pp_take: move s8 trytes, which pipe s1 holds, from it to pp_tmp.
# pp_put: move s8 trytes from pp_tmp into pipe s1, which has room. s2 is
# the pipe's entries' offset. Clobber t0..t5.
pp_take:
        li    t5, 0                    # t5: 0 taking
        j     1f
pp_put:
        li    t5, 1                    # t5: 1 putting
1:      li    t0, PP_SIZE
        mul   t1, s1, t0
        la    t0, pp_ring
        add   t1, t1, t0               # t1: the pipe's buffer
        la    t0, pp_heads
        add   t0, t0, s2
        lw    t2, 0(t0)                # t2: where it starts
        la    t0, pp_counts
        add   t0, t0, s2
        lw    t3, 0(t0)                # t3: what it holds
        beqz  t5, 2f
        add   t2, t2, t3               # putting: at its end
2:      li    t4, 0                    # t4: trytes moved
3:      li    t0, PP_SIZE
        blt   t2, t0, 4f
        sub   t2, t2, t0               # round the buffer
4:      add   t0, t1, t2               # t0: there in the buffer
        la    a5, pp_tmp
        add   a5, a5, t4               # a5: there in pp_tmp
        beqz  t5, 5f
        lt    a0, 0(a5)
        st    a0, 0(t0)
        j     6f
5:      lt    a0, 0(t0)
        st    a0, 0(a5)
6:      addi  t2, t2, 1
        addi  t4, t4, 1
        blt   t4, s8, 3b
        la    t0, pp_counts
        add   t0, t0, s2
        beqz  t5, 7f
        add   t3, t3, s8               # put: it holds more
        sw    t3, 0(t0)
        ret
7:      sub   t3, t3, s8               # taken: less, starting further on
        sw    t3, 0(t0)
        li    t0, PP_SIZE
        blt   t2, t0, 8f
        sub   t2, t2, t0
8:      la    t0, pp_heads
        add   t0, t0, s2
        sw    t2, 0(t0)
        ret

pp_used:  .words PP_NPIPE              # each pipe: 1 while in use,
pp_heads: .words PP_NPIPE              # where what it holds starts,
pp_counts: .words PP_NPIPE             # how much it holds,
pp_rgone: .words PP_NPIPE              # 1 once its read end has closed,
pp_wgone: .words PP_NPIPE              # 1 once its write end has
pp_kinds: .words NPROC                 # each process's held call: PP_READER,
                                       # PP_WRITER, or 0 for none;
pp_pipes: .words NPROC                 # on which pipe,
pp_bufs:  .words NPROC                 # its buffer,
pp_ns:    .words NPROC                 # its n,
pp_dones: .words NPROC                 # and, writing, how much has gone in
pp_name:  .string "pipe"
pp_myname: .string "piped"
pp_tmp:   .zero PP_CHUNK               # what one copy moves
pp_ring:  .zero PP_NPIPE * PP_SIZE     # the pipes' buffers
        .nocompress
