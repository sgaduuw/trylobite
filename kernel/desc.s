# Descriptors: a table in each process's record, turning read and write
# on a number into calls to the server behind it. The kernel keeps only
# the routing: which server, and the handle that server gave out. Only
# the server puts a descriptor into a table (give), so a handle cannot be
# forged; and since SYS_CALL refuses the IO_ operations, a server that
# gets one knows the kernel brought it from a descriptor it gave. The
# kernel tells the server when the last descriptor naming a handle goes,
# so the server never has to know who holds its handles.

        .compress
# read(fd, buffer, n), write(fd, buffer, n) and iocall(fd, op, x, y):
# call fd's server with the IO_ operation, the handle, and the two
# arguments. The call goes on as sys_call, from the rewritten saved
# registers, so the caller sees what a call leaves.
sys_read:
        li    t3, IO_READ
        j     1f
sys_write:
        li    t3, IO_WRITE
1:      lw    t5, PCB_A2(s0)
        lw    t6, PCB_A3(s0)
        j     2f
sys_iocall:
        lw    t3, PCB_A2(s0)           # t3: the operation
        bgez  t3, 8f
        li    t0, IO_FIRST
        blt   t3, t0, 8f
        lw    t5, PCB_A3(s0)
        lw    t6, PCB_A4(s0)
2:      call  desc_of
        bltz  a0, sys_return
        lw    t1, 0(t0)                # the server plus 1
        lw    t2, 3(t0)                # the handle
        sw    t6, PCB_A5(s0)
        sw    t5, PCB_A4(s0)
        sw    t2, PCB_A3(s0)
        sw    t3, PCB_A2(s0)
        addi  a1, t1, -1
        sw    a1, PCB_A1(s0)
        j     sys_call
8:      li    a0, E_INVAL
        j     sys_return

# close(fd)
sys_close:
        call  desc_of
        bltz  a0, sys_return
        lw    a2, 0(t0)
        lw    a3, 3(t0)
        sw    zero, 0(t0)
        sw    zero, 3(t0)
        call  desc_unref
        li    a0, 0
        j     sys_return

# dup2(fd, to): to becomes a copy of fd; what to held is closed.
sys_dup2:
        call  desc_of
        bltz  a0, sys_return
        mv    a4, t0                   # a4: fd's descriptor
        mv    a1, a2
        call  desc_of_any
        bltz  a0, sys_return
        beq   t0, a4, 9f               # onto itself: nothing changes
        lw    a2, 0(t0)                # what it held
        lw    a3, 3(t0)
        lw    t1, 0(a4)
        sw    t1, 0(t0)
        lw    t1, 3(a4)
        sw    t1, 3(t0)
        beqz  a2, 9f
        call  desc_unref
9:      mv    a0, a1
        j     sys_return

# give(pid, handle): put the caller's handle in process pid's lowest free
# descriptor. Pid must be waiting for the caller's reply, so a server
# gives only to a process that asked it for something.
sys_give:
        bltz  a2, 8f
        li    t0, NHANDLE
        bge   a2, t0, 8f
        call  client_of
        bltz  a0, sys_return
        call  current_pid
        addi  t3, a0, 1                # t3: the server plus 1
        addi  t0, s1, PCB_DESCS
        li    a0, 0                    # a0: the descriptor
1:      lw    t1, 0(t0)
        beqz  t1, 2f
        addi  t0, t0, DESC
        addi  a0, a0, 1
        li    t1, NDESC
        blt   a0, t1, 1b
        li    a0, E_MFILE
        j     sys_return
2:      sw    t3, 0(t0)
        sw    a2, 3(t0)
        add   t0, s0, a2               # a descriptor names it again: a
        st    zero, PCB_CLOSED(t0)     # notice not yet taken is stale
        j     sys_return
8:      li    a0, E_INVAL
        j     sys_return

# desc_of: t0 = the address of descriptor a1 of the process in s0, and
# a0 = 0, if it names something; else a0 = E_BADF. desc_of_any: the same
# for any descriptor in range, naming something or not. Clobbers t0, t1.
desc_of:
        li    t1, 1                    # t1: 1 if it must name something
        j     1f
desc_of_any:
        li    t1, 0
1:      bltz  a1, 8f
        li    t0, NDESC
        bge   a1, t0, 8f
        li    t0, DESC
        mul   t0, a1, t0
        add   t0, t0, s0
        addi  t0, t0, PCB_DESCS
        beqz  t1, 2f
        lw    a0, 0(t0)
        beqz  a0, 8f
2:      li    a0, 0
        ret
8:      li    a0, E_BADF
        ret

# desc_unref: a descriptor naming handle a3 of server a2 - 1 is gone. If
# none is left anywhere, tell the server, if it is still there, with a
# NOTE_CLOSED notice. Clobbers s1, t0..t3.
desc_unref:
        la    s1, procs
1:      addi  t0, s1, PCB_DESCS
        li    t1, NDESC
2:      lw    t2, 0(t0)
        bne   t2, a2, 3f
        lw    t2, 3(t0)
        beq   t2, a3, 9f               # still named
3:      addi  t0, t0, DESC
        addi  t1, t1, -1
        bnez  t1, 2b
        addi  s1, s1, PCB_SIZE
        la    t0, procs + NPROC * PCB_SIZE
        blt   s1, t0, 1b
        addi  t0, a2, -1               # nothing names it: the server
        li    t1, PCB_SIZE
        mul   t0, t0, t1
        la    s1, procs
        add   s1, s1, t0
        beq   s1, s0, 9f               # ending itself (desc_ended)
        lw    t0, PCB_STATE(s1)
        beqz  t0, 9f
        li    t1, ST_ZOMBIE
        beq   t0, t1, 9f
        add   t0, s1, a3
        li    t1, 1
        st    t1, PCB_CLOSED(t0)
        j     rouse                    # returns to our caller
9:      ret

# desc_ended: process t4, in s0, has ended (bury). Its descriptors close,
# and those naming it, which no call can reach now, go: a later process
# with its number never sees calls for handles it did not give.
# Clobbers s1, a2..a5, t0..t3.
desc_ended:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        addi  a4, s0, PCB_DESCS
        li    a5, NDESC
1:      lw    a2, 0(a4)
        beqz  a2, 2f
        lw    a3, 3(a4)
        sw    zero, 0(a4)
        sw    zero, 3(a4)
        call  desc_unref
2:      addi  a4, a4, DESC
        addi  a5, a5, -1
        bnez  a5, 1b
        addi  t3, t4, 1                # t3: what names it
        la    s1, procs
3:      addi  t0, s1, PCB_DESCS
        li    t1, NDESC
4:      lw    t2, 0(t0)
        bne   t2, t3, 5f
        sw    zero, 0(t0)
        sw    zero, 3(t0)
5:      addi  t0, t0, DESC
        addi  t1, t1, -1
        bnez  t1, 4b
        addi  s1, s1, PCB_SIZE
        la    t0, procs + NPROC * PCB_SIZE
        blt   s1, t0, 3b
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# desc_inherit: give the record in s1 copies of the descriptors of
# process a2, its parent, if it has one. Clobbers t0..t3.
desc_inherit:
        bltz  a2, 9f
        li    t0, PCB_SIZE
        mul   t0, a2, t0
        la    t1, procs
        add   t0, t0, t1
        addi  t0, t0, PCB_DESCS        # t0: the parent's table
        addi  t1, s1, PCB_DESCS        # t1: the child's
        li    t2, NDESC * DESC / 3
1:      lw    t3, 0(t0)
        sw    t3, 0(t1)
        addi  t0, t0, 3
        addi  t1, t1, 3
        addi  t2, t2, -1
        bnez  t2, 1b
9:      ret
        .nocompress
