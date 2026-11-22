# Server names: a server registers a name, with the version of the
# protocol it speaks, once it is ready for calls; a client looks the
# name up to find the server's process number, and can sleep until it
# is there. So no server needs a fixed process number, and a client
# that starts before its server waits instead of failing.
#
# The kernel keeps the names, not a server: a naming server would need
# a fixed number itself, take one of the NPROC slots, and cost every
# lookup a call and a reply. The kernel also sees every process end
# (bury), so a name goes the moment its server does, with no notice to
# pass on: a name that is there belongs to a live process.
#
# A record is free while its SRV_VERSION is 0. Names are compared whole,
# zero-padded to SRV_NAME_MAX + 1 trytes, as srv_key holds them.

        .compress
# register(name, version)
sys_register:
        mv    s3, a2                   # s3: the version
        blez  s3, 8f
        call  srv_key_in
        bltz  a0, sys_return
        call  current_pid
        mv    s4, a0                   # s4: this process
        call  srv_find
        beqz  s2, 1f
        lw    t0, SRV_PID(s2)
        bne   t0, s4, 7f
        j     3f                       # its own name: a new version
1:      la    s2, names                # a free record
        li    t3, NSRV
2:      lw    t0, SRV_VERSION(s2)
        beqz  t0, 4f
        addi  s2, s2, SRV
        addi  t3, t3, -1
        bnez  t3, 2b
        li    a0, E_NOSPC
        j     sys_return
4:      la    t1, srv_key
        li    t3, SRV_NAME_MAX + 1
5:      lt    t0, 0(t1)
        st    t0, SRV_NAME(s2)
        addi  t1, t1, 1
        addi  s2, s2, 1
        addi  t3, t3, -1
        bnez  t3, 5b
        addi  s2, s2, -SRV_NAME_MAX - 1
        sw    s4, SRV_PID(s2)
3:      sw    s3, SRV_VERSION(s2)
        call  srv_wake
        li    a0, 0
        j     sys_return
7:      li    a0, E_EXIST
        j     sys_return
8:      li    a0, E_INVAL
        j     sys_return

# lookup(name, how): sleeping in it, a process is woken by every
# register, and runs it again (PCB_RETRY), so it changes nothing before
# it finds the name.
sys_lookup:
        mv    s3, a2                   # s3: how
        call  srv_key_in
        bltz  a0, sys_return
        call  srv_find
        beqz  s2, 1f
        lw    t0, SRV_VERSION(s2)
        sw    t0, PCB_A1(s0)
        lw    a0, SRV_PID(s2)
        j     sys_return
1:      li    t0, LOOKUP_WAIT
        bne   s3, t0, 2f
        li    t0, ST_LOOKUP
        sw    t0, PCB_STATE(s0)
        j     schedule
2:      li    a0, E_NOENT
        j     sys_return

# srv_key_in: copy the name at a1 in the caller's memory (its page, or a
# block window it has) to srv_key, zero-padded: a0 = 0, or E_FAULT (it
# leaves the caller's memory before its 0), E_NAMETOOLONG or E_INVAL
# (empty). Clobbers a1, s5..s7 and t0..t2.
srv_key_in:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        mv    s5, a1                   # s5: where the name goes on
        la    s6, srv_key              # s6: where it is copied to
        li    s7, SRV_NAME_MAX + 1     # s7: room left, its 0 counted
1:      mv    a0, s0
        mv    a1, s5
        call  uva
        beqz  a0, 7f
2:      lt    t0, 0(a0)
        st    t0, 0(s6)
        beqz  t0, 3f
        addi  s6, s6, 1
        addi  s7, s7, -1
        beqz  s7, 6f
        addi  s5, s5, 1
        addi  a0, a0, 1
        addi  a1, a1, -1
        bnez  a1, 2b
        j     1b                       # on into the next page, if mapped
3:      li    t0, SRV_NAME_MAX + 1
        beq   s7, t0, 8f               # the 0 came first
4:      addi  s7, s7, -1               # pad: the 0 is in place already
        beqz  s7, 5f
        addi  s6, s6, 1
        st    zero, 0(s6)
        j     4b
5:      li    a0, 0
        j     9f
6:      li    a0, E_NAMETOOLONG
        j     9f
7:      li    a0, E_FAULT
        j     9f
8:      li    a0, E_INVAL
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# srv_find: s2 = the record whose name is srv_key, or 0. Clobbers t0..t5.
srv_find:
        la    s2, names
        li    t4, NSRV
1:      lw    t0, SRV_VERSION(s2)
        beqz  t0, 4f
        la    t1, srv_key
        mv    t2, s2
        li    t3, SRV_NAME_MAX + 1
2:      lt    t0, 0(t1)
        lt    t5, SRV_NAME(t2)
        bne   t0, t5, 4f
        addi  t1, t1, 1
        addi  t2, t2, 1
        addi  t3, t3, -1
        bnez  t3, 2b
        ret
4:      addi  s2, s2, SRV
        addi  t4, t4, -1
        bnez  t4, 1b
        li    s2, 0
        ret

# srv_wake: a name came or changed: every process asleep in lookup looks
# again. Clobbers s1, t0..t3.
srv_wake:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    s1, procs
1:      lw    t0, PCB_STATE(s1)
        li    t1, ST_LOOKUP
        bne   t0, t1, 2f
        li    t0, 1
        sw    t0, PCB_RETRY(s1)
        li    t0, ST_READY
        sw    t0, PCB_STATE(s1)
        call  wake_one
2:      addi  s1, s1, PCB_SIZE
        la    t0, procs + NPROC * PCB_SIZE
        blt   s1, t0, 1b
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# srv_ended: process t4 has ended (bury): its names go. Clobbers t0, t1.
srv_ended:
        la    t1, names
1:      lw    t0, SRV_PID(t1)
        bne   t0, t4, 2f
        sw    zero, SRV_VERSION(t1)
2:      addi  t1, t1, SRV
        la    t0, names + NSRV * SRV
        blt   t1, t0, 1b
        ret
        .nocompress
