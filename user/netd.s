# The network server: the network device's driver, as a process. It
# drives source SRC_NET (SYS_DRIVE), so the device's registers are mapped
# into it and its interrupts come to it as notices, and registers as
# "net", protocol NET_PROTOCOL, before it takes its first call. Clients
# find it by that name (SYS_LOOKUP); a network stack is the one it is for.
#
# A network call is a SYS_CALL with an NT_ operation in a2 and the
# arguments in a3 and a4 (include/layout.s). Frames pass through two
# block windows of the server's: window 0 holds the frame being sent and
# window 1 the receive buffer the device fills, each told to the device
# once, by physical address. Only the server's windows are ever given to
# the device, so a client that ends cannot have its freed page written.
#
# Sending: a send's call is held, one per process (nt_sends), and the
# next is started, in process order after the last, when the device is
# free: its frame is copied into window 0 and the device takes it at
# once, failing it there if it is no frame; otherwise the caller is
# answered when the device has finished sending.
#
# Receiving: window 1 is given to the device whenever it holds no frame
# for a reader, and the device keeps up to nine more while it is full. A
# receive's call is held, one per process (nt_recvs), until a frame is
# there; frames go to waiting readers in process order after the last.
# A frame that arrives while nobody reads waits in window 1 (nt_held).
#
# Listening: a network stack cannot wait in a receive and take calls at
# once, so it calls NT_LISTEN instead, and the server notifies it
# (SYS_NOTIFY) once for each frame that waits with nobody reading; its
# receive then takes the frame at once. One process listens at a time.
#
# The server arms the device's interrupt only while it waits on the
# device for somebody: a send in flight, or a reader or listener with no
# frame to give. An armed device keeps the machine on only while some
# process waits on something, so a listener alone does not.
#
# Not a program on its own: a build includes it in a program's section.
# Its labels all start with nt_, since it shares the build's symbols.

        .compress
        .gp   USER_GP

        .equ  NT_REGS, V_DEVICE + PAGE * (SRC_NET - 1)   # the device's registers
        .equ  NT_TXBUF, V_BLOCK + BLOCK_T0             # window 0's first tryte
        .equ  NT_RXBUF, V_BLOCK + PAGE + BLOCK_T0      # window 1's
        .equ  NT_IDLE, -1              # nt_txpid with no send in flight

nt_main:
        li    a0, SYS_NAME             # for ps: a program of the image
        la    a1, nt_myname            # has no argv[0] to name it
        sys
        li    a0, SYS_DRIVE
        li    a1, SRC_NET
        sys
        bltz  a0, nt_quit
        li    s1, 0                    # windows 0 and 1, told to the device
1:      li    a0, SYS_WINDOW
        mv    a1, s1
        sys
        bltz  a0, nt_quit
        li    a0, SYS_PHYS
        li    a1, PAGE
        mul   a1, a1, s1
        li    t0, V_BLOCK
        add   a1, a1, t0
        sys
        bltz  a0, nt_quit
        addi  a0, a0, BLOCK_T0
        li    t0, NT_REGS
        bnez  s1, 2f
        sw    a0, NET_TX_ADDR(t0)
        li    s1, 1
        j     1b
2:      sw    a0, NET_RX_ADDR(t0)
        li    t1, FRAME_MAX
        sw    t1, NET_RX_SIZE(t0)
        li    t1, NET_RECEIVE
        sw    t1, NET_RX_COMMAND(t0)
        li    a0, SYS_REGISTER
        la    a1, nt_name
        li    a2, NET_PROTOCOL
        sys
        bgez  a0, nt_wait
nt_quit:                               # a0: why it cannot serve
        mv    a1, a0
        li    a0, SYS_EXIT
        sys

nt_wait:
        li    sp, USER_SP
        li    a0, SYS_RECEIVE
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, nt_notice
        mv    s0, a0                   # s0: the caller
        li    t0, NT_ADDRESS
        beq   a1, t0, nt_address
        li    t0, NT_LISTEN
        beq   a1, t0, nt_listen
        li    a5, E_INVAL
        li    t0, NT_SEND
        beq   a1, t0, nt_send
        li    t0, NT_RECEIVE
        bne   a1, t0, nt_answer
        blez  a3, nt_answer            # receive: a buffer of some size
        la    s1, nt_recvs
        j     nt_hold
nt_send:
        li    t0, FRAME_MIN
        blt   a3, t0, nt_answer
        li    t0, FRAME_MAX
        bgt   a3, t0, nt_answer
        la    s1, nt_sends
# nt_hold: keep process s0's call, buffer a2 and count a3, in its entries
# of the table at s1 (count plus 1, 0 for none) and the buffers after it,
# NPROC words on; then see what can move.
nt_hold:
        li    a5, E_IO                 # nothing moves without a link
        li    t0, NT_REGS
        lw    t0, NET_LINK(t0)
        blez  t0, nt_answer
        li    t0, 3
        mul   t0, s0, t0
        add   t0, t0, s1
        addi  a3, a3, 1
        sw    a3, 0(t0)
        sw    a2, 3 * NPROC(t0)
        j     nt_poll

nt_address:
        li    t0, NT_REGS
        li    a0, SYS_REPLY
        mv    a1, s0
        li    a2, 0
        lw    a3, NET_MAC_HI(t0)
        lw    a4, NET_MAC_LO(t0)
        sys
        j     nt_wait

nt_listen:
        sw    s0, nt_listener
        sw    zero, nt_told            # a frame waiting is news to it
        li    a0, SYS_REPLY
        mv    a1, s0
        li    a2, 0
        sys
        j     nt_poll

# nt_answer: reply a5 to process s0, and go back to waiting.
nt_answer:
        li    a0, SYS_REPLY
        mv    a1, s0
        mv    a2, a5
        sys
        j     nt_wait

nt_notice:
        li    t0, NOTE_IRQ
        beq   a1, t0, nt_poll
        li    t0, NOTE_ENDED           # what it waited for goes with it
        bne   a1, t0, nt_wait
        li    t0, 3
        mul   t0, a2, t0
        la    t1, nt_sends
        add   t1, t1, t0
        sw    zero, 0(t1)
        la    t1, nt_recvs
        add   t1, t1, t0
        sw    zero, 0(t1)
        lw    t0, nt_listener
        bne   t0, a2, 1f
        li    t0, NT_IDLE
        sw    t0, nt_listener
1:      lw    t0, nt_txpid
        bne   t0, a2, nt_wait
        li    t0, 1                    # the send in flight is nobody's now,
        sw    t0, nt_txgone            # and the number may come back
        j     nt_wait

# nt_poll: move everything the device lets move: finish a send, start
# the next, take a frame that has come, give it to a reader; then arm the
# interrupt if somebody still waits on the device, and wait for calls.
nt_poll:
        lw    s0, nt_txpid
        bltz  s0, nt_next
        li    t0, NT_REGS
        lw    t1, NET_TX_STATUS(t0)
        li    t2, NET_BUSY
        beq   t1, t2, nt_rx            # still sending
        sw    zero, NET_TX_ACK(t0)
        li    t0, NT_IDLE
        sw    t0, nt_txpid
        lw    t0, nt_txgone
        bnez  t0, nt_next
        call  nt_txreply

# nt_next: start the next waiting send, after the last one started, if
# any waits.
nt_next:
        la    a0, nt_sends
        lw    a1, nt_txlast
        call  nt_find
        bltz  s0, nt_rx
        sw    s0, nt_txlast
        lw    s2, 0(t0)
        addi  s2, s2, -1               # s2: its length
        lw    a2, 3 * NPROC(t0)
        sw    zero, 0(t0)
        li    a0, SYS_COPYIN
        mv    a1, s0
        li    a3, NT_TXBUF
        mv    a4, s2
        sys
        li    a5, E_FAULT
        bnez  a0, 1f
        li    t0, NT_REGS
        sw    s2, NET_TX_LEN(t0)
        li    t1, NET_SEND
        sw    t1, NET_TX_COMMAND(t0)
        lw    t1, NET_TX_STATUS(t0)
        li    t2, NET_BUSY
        bne   t1, t2, 2f               # refused at once
        sw    s0, nt_txpid
        sw    zero, nt_txgone
        j     nt_rx
2:      sw    zero, NET_TX_ACK(t0)
        call  nt_txreply
        j     nt_next
1:      li    a0, SYS_REPLY
        mv    a1, s0
        mv    a2, a5
        sys
        j     nt_next

# nt_rx: take a frame the device has put in window 1, and give a held
# one to the next waiting reader.
nt_rx:
        lw    t0, nt_held
        bnez  t0, 1f
        li    t0, NT_REGS
        lw    t1, NET_RX_STATUS(t0)
        li    t2, NET_BUSY
        beq   t1, t2, nt_arm           # nothing yet
        sw    zero, NET_RX_ACK(t0)
        li    t2, NET_FAILED
        beq   t1, t2, 3f               # cannot happen: window 1 is RAM
        li    t1, 1
        sw    t1, nt_held
1:      la    a0, nt_recvs
        lw    a1, nt_rxlast
        call  nt_find
        bltz  s0, nt_tell              # nobody reads: it waits
        sw    s0, nt_rxlast
        lw    s2, 0(t0)
        addi  s2, s2, -1               # s2: the reader's size
        lw    a3, 3 * NPROC(t0)
        sw    zero, 0(t0)
        li    t0, NT_REGS
        lw    s3, NET_RX_LEN(t0)       # s3: the frame's length
        li    a2, E_NOROOM
        bgt   s3, s2, 2f
        li    a0, SYS_COPYOUT
        mv    a1, s0
        li    a2, NT_RXBUF
        mv    a4, s3
        sys
        mv    a2, s3
        beqz  a0, 2f
        li    a2, E_FAULT
2:      li    a0, SYS_REPLY
        mv    a1, s0
        sys
3:      sw    zero, nt_held            # window 1 to the device again
        sw    zero, nt_told
        li    t0, NT_REGS
        li    t1, NET_RECEIVE
        sw    t1, NET_RX_COMMAND(t0)
        j     nt_rx

# nt_tell: a frame waits with nobody reading: tell the listener, once.
nt_tell:
        lw    a1, nt_listener
        bltz  a1, nt_arm
        lw    t0, nt_told
        bnez  t0, nt_arm
        li    t0, 1
        sw    t0, nt_told
        li    a0, SYS_NOTIFY
        sys

# nt_arm: let the device interrupt if somebody waits on it: a send in
# flight, or a reader or listener with no frame to give it. The
# interrupt is level-triggered, so one that came first is not lost.
nt_arm:
        lw    t0, nt_txpid
        bgez  t0, 1f
        lw    t0, nt_held
        bnez  t0, nt_wait
        lw    t0, nt_listener
        bgez  t0, 1f
        la    a0, nt_recvs
        li    a1, 0
        call  nt_find
        bltz  s0, nt_wait
1:      li    a0, SYS_ARM
        li    a1, SRC_NET
        sys
        j     nt_wait

# nt_txreply: answer process s0's send as the device says it went.
nt_txreply:
        li    t0, NT_REGS
        lw    t1, NET_TX_STATUS(t0)
        li    a2, 0
        li    t2, NET_FAILED
        bne   t1, t2, 1f
        li    a2, E_IO
1:      li    a0, SYS_REPLY
        mv    a1, s0
        sys
        ret

# nt_find: s0 = the first process after a1, in turn, with a call in the
# table at a0, and t0 its entry; s0 = NT_IDLE if none has.
nt_find:
        mv    s0, a1
        li    t2, NPROC                # t2: how many are left to look at
1:      addi  s0, s0, 1
        li    t0, NPROC
        blt   s0, t0, 2f
        li    s0, 0
2:      li    t0, 3
        mul   t0, s0, t0
        add   t0, t0, a0
        lw    t1, 0(t0)
        bnez  t1, 3f
        addi  t2, t2, -1
        bnez  t2, 1b
        li    s0, NT_IDLE
3:      ret

nt_txpid: .word NT_IDLE                # whose send is in flight
nt_txgone: .word 0                     # 1 if that process has ended since
nt_txlast: .word NPROC - 1             # whose send was started last
nt_rxlast: .word NPROC - 1             # who was given a frame last
nt_held: .word 0                       # 1 while window 1 holds a frame
nt_listener: .word NT_IDLE             # who listens, NT_IDLE for nobody
nt_told: .word 0                       # 1 once the listener knows of it
nt_sends: .words NPROC                 # each process's waiting send: its
nt_sbufs: .words NPROC                 # length plus 1 (0 for none), and frame
nt_recvs: .words NPROC                 # each process's waiting receive: its
nt_rbufs: .words NPROC                 # size plus 1 (0 for none), and buffer
nt_name: .string "net"
nt_myname: .string "netd"
        .nocompress
