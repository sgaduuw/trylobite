# Descriptors: a table in each process's record, turning read and write
# on a number into calls to the server behind it. The kernel keeps only
# the routing: which server, and the handle that server gave out. It
# checks neither, since the server sees the caller as it would any
# call's, and judges the handle itself.

        .compress
# read(fd, buffer, n) and write(fd, buffer, n): call fd's server with
# IO_READ or IO_WRITE, the handle, the buffer and n. The call goes on as
# sys_call, from the rewritten saved registers, so the caller sees what a
# call leaves.
sys_read:
        li    t3, IO_READ
        j     1f
sys_write:
        li    t3, IO_WRITE
1:      call  desc_of
        bltz  a0, sys_return
        lw    t1, 0(t0)                # the server plus 1
        lw    t2, 3(t0)                # the handle
        lw    t0, PCB_A3(s0)
        sw    t0, PCB_A5(s0)           # n
        lw    t0, PCB_A2(s0)
        sw    t0, PCB_A4(s0)           # the buffer
        sw    t2, PCB_A3(s0)
        sw    t3, PCB_A2(s0)
        addi  a1, t1, -1
        sw    a1, PCB_A1(s0)
        j     sys_call

# desc(fd, server, handle): make fd name handle at server, or nothing.
sys_desc:
        call  desc_of_any
        bltz  a0, sys_return
        li    t1, NO_DESC
        beq   a2, t1, 2f
        bltz  a2, 3f                   # no process has a negative number
        addi  t1, a2, 1
        sw    t1, 0(t0)
        lw    t1, PCB_A3(s0)
        sw    t1, 3(t0)
        li    a0, 0
        j     sys_return
2:      sw    zero, 0(t0)
        sw    zero, 3(t0)
        li    a0, 0
        j     sys_return
3:      li    a0, E_NOPROC
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
