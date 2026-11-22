# Messages for servers: call, receive and reply, and copying between a
# server and a process whose call it holds.
#
# A call is four words, sent from the caller's a2..a5; the caller sleeps
# until the server replies with four words of its own, which its call
# returns in a0..a3. The server takes calls one at a time with receive,
# which says who sent each; while it holds a call (the caller is
# ST_REPLY, with the server as its PCB_PEER), it may copy to and from the
# caller's memory with copyin and copyout. That is how a buffer or a path
# travels: the call names an address, and the server copies.
#
# A process that has called receive once is told of every process that
# ends, by a message from FROM_KERNEL, before any call that came later,
# so a server can drop what it kept for a process before a new process
# with the same number reaches it. A process that ends while others call
# it fails their calls with E_NOPROC.
#
# A server asleep in receive is woken by setting PCB_RETRY: it runs
# receive again and finds the call or the notice itself.

        .compress
# call(pid, w1, w2, w3, w4). A negative w1 is an IO_ operation, which
# only a descriptor call (desc.s) may send, from sys_call.
sys_call_user:
        bgez  a2, sys_call
        li    a0, E_INVAL
        j     sys_return
sys_call:
        call  proc_of
        bltz  a0, sys_return
        beq   s1, s0, 8f
        sw    a1, PCB_PEER(s0)
        li    t0, ST_CALL
        sw    t0, PCB_STATE(s0)
        call  rouse
        j     schedule
8:      li    a0, E_SELF
        j     sys_return

# receive(): a notice first (an interrupt's, then a closed handle's, then
# an ending's), else the next caller after the last one taken, else sleep
# until rouse wakes it.
sys_receive:
        li    t0, 1
        sw    t0, PCB_SERVES(s0)
        li    t3, 1                    # t3: a source it may drive
0:      add   t2, s0, t3
        lt    t0, PCB_IRQS - 1(t2)
        bnez  t0, 7f
        addi  t3, t3, 1
        li    t1, NSRC
        ble   t3, t1, 0b
        li    t3, 0                    # t3: a handle
0:      add   t2, s0, t3
        lt    t0, PCB_CLOSED(t2)
        bnez  t0, 9f
        addi  t3, t3, 1
        li    t1, NHANDLE
        blt   t3, t1, 0b
        li    t3, 0                    # t3: a process number
1:      add   t2, s0, t3
        lt    t0, PCB_NOTES(t2)
        bnez  t0, 2f
        addi  t3, t3, 1
        li    t1, NPROC
        blt   t3, t1, 1b

        call  current_pid
        mv    s3, a0                   # s3: this server's number
        lw    t3, PCB_TURN(s0)
        li    t4, NPROC
3:      addi  t3, t3, 1
        li    t1, NPROC
        blt   t3, t1, 4f
        li    t3, 0
4:      li    t0, PCB_SIZE
        mul   t0, t3, t0
        la    s2, procs
        add   s2, s2, t0               # s2: process t3
        lw    t0, PCB_STATE(s2)
        li    t1, ST_CALL
        bne   t0, t1, 5f
        lw    t0, PCB_PEER(s2)
        beq   t0, s3, 6f
5:      addi  t4, t4, -1
        bnez  t4, 3b
        li    t0, ST_RECEIVE
        sw    t0, PCB_STATE(s0)
        j     schedule

2:      li    t0, 0                    # a notice: process t3 ended
        st    t0, PCB_NOTES(t2)
        li    t0, NOTE_ENDED
        j     8f
7:      li    t0, 0                    # a notice: source t3 interrupted
        st    t0, PCB_IRQS - 1(t2)
        li    t0, NOTE_IRQ
        j     8f
9:      li    t0, 0                    # a notice: handle t3 is closed
        st    t0, PCB_CLOSED(t2)
        li    t0, NOTE_CLOSED
8:      sw    t0, PCB_A1(s0)
        sw    t3, PCB_A2(s0)
        li    a0, FROM_KERNEL
        j     sys_return

6:      sw    t3, PCB_TURN(s0)         # process t3's call
        li    t0, ST_REPLY
        sw    t0, PCB_STATE(s2)
        lw    t0, PCB_A2(s2)
        sw    t0, PCB_A1(s0)
        lw    t0, PCB_A3(s2)
        sw    t0, PCB_A2(s0)
        lw    t0, PCB_A4(s2)
        sw    t0, PCB_A3(s0)
        lw    t0, PCB_A5(s2)
        sw    t0, PCB_A4(s0)
        mv    a0, t3
        j     sys_return

# reply(pid, w1, w2, w3, w4): the caller's call returns them.
sys_reply:
        call  client_of
        bltz  a0, sys_return
        lw    t0, PCB_A2(s0)
        sw    t0, PCB_A0(s1)
        lw    t0, PCB_A3(s0)
        sw    t0, PCB_A1(s1)
        lw    t0, PCB_A4(s0)
        sw    t0, PCB_A2(s1)
        lw    t0, PCB_A5(s0)
        sw    t0, PCB_A3(s1)
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        call  wake_one
        li    a0, 0
        j     sys_return

# copyin(pid, from, to, n): from the caller's memory to the server's.
sys_copyin:
        call  client_of
        bltz  a0, sys_return
        mv    s2, s1
        mv    s4, s0
        j     1f
# copyout(pid, from, to, n): from the server's memory to the caller's.
sys_copyout:
        call  client_of
        bltz  a0, sys_return
        mv    s2, s0
        mv    s4, s1
1:      lw    s3, PCB_A2(s0)
        lw    s5, PCB_A3(s0)
        lw    s6, PCB_A4(s0)
        call  copy_mem
        j     sys_return

# proc_of: s1 = the record of process a1 and a0 = 0, if it is alive;
# else a0 = E_NOPROC. Clobbers t0, t1.
proc_of:
        bltz  a1, 8f
        li    t0, NPROC
        bge   a1, t0, 8f
        li    t0, PCB_SIZE
        mul   t1, a1, t0
        la    s1, procs
        add   s1, s1, t1
        lw    t0, PCB_STATE(s1)
        beqz  t0, 8f                   # a free slot
        li    t1, ST_ZOMBIE
        beq   t0, t1, 8f
        li    a0, 0
        ret
8:      li    a0, E_NOPROC
        ret

# client_of: as proc_of, and process a1 must be waiting for this process's
# reply (ST_REPLY, its PCB_PEER this process). Clobbers t0, t1.
client_of:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  proc_of
        bltz  a0, 9f
        lw    t0, PCB_STATE(s1)
        li    t1, ST_REPLY
        bne   t0, t1, 8f
        call  current_pid
        lw    t0, PCB_PEER(s1)
        bne   t0, a0, 8f
        li    a0, 0
        j     9f
8:      li    a0, E_NOPROC
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# rouse: wake process s1 if it sleeps in receive, to run it again.
# Clobbers t0..t2.
rouse:
        lw    t0, PCB_STATE(s1)
        li    t1, ST_RECEIVE
        bne   t0, t1, 9f
        li    t0, 1
        sw    t0, PCB_RETRY(s1)
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        j     wake_one                 # returns to our caller
9:      ret

# ipc_ended: process t4, in s0, has ended (bury). Tell every process
# that receives, and fail the calls made to it. Clobbers s1, t0..t3.
ipc_ended:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    s1, procs
1:      beq   s1, s0, 4f
        lw    t0, PCB_STATE(s1)
        beqz  t0, 4f
        lw    t1, PCB_SERVES(s1)
        beqz  t1, 2f
        add   t1, s1, t4
        li    t2, 1
        st    t2, PCB_NOTES(t1)
        call  rouse
        lw    t0, PCB_STATE(s1)
2:      li    t1, ST_CALL
        beq   t0, t1, 3f
        li    t1, ST_REPLY
        bne   t0, t1, 4f
3:      lw    t1, PCB_PEER(s1)
        bne   t1, t4, 4f
        li    t0, E_NOPROC             # its call fails
        sw    t0, PCB_A0(s1)
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        call  wake_one
4:      addi  s1, s1, PCB_SIZE
        la    t0, procs + NPROC * PCB_SIZE
        blt   s1, t0, 1b
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# uva: a0 = the kernel address of address a1 in the process whose record
# is in a0, and a1 = how many trytes its page has from there, or a0 = 0
# when the process has nothing there: its own page, or a block window it
# has. Clobbers t0..t2.
uva:
        li    t0, V_USER - 9841
        sub   t1, a1, t0               # t1: trytes from the page's first
        bltz  t1, 8f
        li    t0, PAGE
        div   t2, t1, t0               # t2: 0 its page, k + 1 window k
        mul   t0, t2, t0
        sub   t1, t1, t0               # t1: trytes into that page, 0 to PAGE - 1
        beqz  t2, 1f
        li    t0, NWIN
        bgt   t2, t0, 8f
        li    t0, 3
        mul   t2, t2, t0
        add   t2, t2, a0
        addi  t2, t2, -3
        lw    t2, PCB_WINS(t2)
        beqz  t2, 8f
        j     2f
1:      lw    t2, PCB_USERPG(a0)
2:      li    t0, PAGE
        sub   a1, t0, t1
        mul   a0, t2, t0
        li    t0, DMAP - 9841
        add   a0, a0, t0
        add   a0, a0, t1
        ret
8:      li    a0, 0
        ret

# copy_mem: copy s6 trytes from s3 in the process whose record is s2 to
# s5 in the one whose record is s4. It checks the whole of both ranges
# first, so it copies all or nothing: a0 = 0, or E_FAULT. Clobbers a0..a3,
# s7 and t0..t5.
copy_mem:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        bltz  s6, 8f
        li    s7, 0                    # s7: 0 checking, 1 copying
1:      mv    t3, s3
        mv    t4, s5
        mv    t5, s6
2:      blez  t5, 6f
        mv    a0, s2
        mv    a1, t3
        call  uva
        beqz  a0, 8f
        mv    a2, a0                   # a2: where from, a3: how far
        mv    a3, a1
        mv    a0, s4
        mv    a1, t4
        call  uva
        beqz  a0, 8f
        ble   a3, a1, 3f
        mv    a3, a1
3:      ble   a3, t5, 4f
        mv    a3, t5
4:      add   t3, t3, a3
        add   t4, t4, a3
        sub   t5, t5, a3
        beqz  s7, 2b
        addi  t0, a2, 1                # Both at a word's first tryte (its
        li    t1, 3                    # centre a multiple of 3): nine
        div   t2, t0, t1               # words at a time while that many
        mul   t2, t2, t1               # are left, then trytes one by one,
        bne   t2, t0, 5f               # since a disk block copied whole
        addi  t0, a0, 1                # from window to window is most of
        div   t2, t0, t1               # what servers copy.
        mul   t2, t2, t1
        bne   t2, t0, 5f
        li    t1, 27
0:      blt   a3, t1, 5f
        lw    t0, 1(a2)
        sw    t0, 1(a0)
        lw    t0, 4(a2)
        sw    t0, 4(a0)
        lw    t0, 7(a2)
        sw    t0, 7(a0)
        lw    t0, 10(a2)
        sw    t0, 10(a0)
        lw    t0, 13(a2)
        sw    t0, 13(a0)
        lw    t0, 16(a2)
        sw    t0, 16(a0)
        lw    t0, 19(a2)
        sw    t0, 19(a0)
        lw    t0, 22(a2)
        sw    t0, 22(a0)
        lw    t0, 25(a2)
        sw    t0, 25(a0)
        addi  a2, a2, 27
        addi  a0, a0, 27
        addi  a3, a3, -27
        j     0b
5:      beqz  a3, 2b
        lt    t0, 0(a2)
        st    t0, 0(a0)
        addi  a2, a2, 1
        addi  a0, a0, 1
        addi  a3, a3, -1
        j     5b
6:      bnez  s7, 7f
        li    s7, 1
        j     1b
7:      li    a0, 0
        j     9f
8:      li    a0, E_FAULT
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret
        .nocompress
