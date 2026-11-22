# The block cache, and system calls that run again. The filesystem's
# system calls read blocks through bget. A block not in the cache cannot
# be waited for halfway through a call: there is one kernel stack, and
# the driver runs one command at a time. So bget starts reading it, puts
# the caller to sleep and abandons the call; once the block is in, the
# caller runs the whole call again from the start (resume, PCB_RETRY),
# finding that block, and any it found before, in the cache. A call
# therefore changes nothing until it has every block it needs, and a
# call needs no more blocks than the cache holds (PATH_DEPTH). A call
# never evicts a block it has used itself (PCB_BSTART), so with too few
# pages for the cache it fails with E_NOMEM instead of chasing its tail.
#
# Slots are reused least recently used first. A slot being filled is
# left alone, and a hit never evicts, so an address bget returned stays
# good until the call ends or abandons itself.

        .compress
# bget: a0 = the kernel address of block a0's centre, from the cache. A
# block that is not there is read, and the call is abandoned and run
# again when it is (not returning). A block past the disk's end, which
# only a damaged filesystem names, ends the call with E_IO; no slot to
# read it into, with E_NOMEM. Clobbers a0, a1 and t0..t5; keeps s1..s8.
bget:
        lw    t5, buf_clock
        addi  t5, t5, 1
        sw    t5, buf_clock            # t5: now
        la    t1, bufs
        li    t2, NBUF
1:      lw    t3, BUF_STATE(t1)
        beqz  t3, 2f                   # BUF_EMPTY
        lw    t4, BUF_BLOCK(t1)
        bne   t4, a0, 2f
        li    t4, BUF_FILLING
        beq   t3, t4, buf_wait         # on its way: wait with the others
        sw    t5, BUF_USED(t1)
        lw    a0, BUF_PAGE(t1)
        j     kva
2:      addi  t1, t1, BUF
        addi  t2, t2, -1
        bnez  t2, 1b

        # A miss. Is the block on the disk at all?
        bltz  a0, 8f
        li    t0, V_DISK
        lw    t0, DISK_BLOCKS(t0)
        bge   a0, t0, 8f
        # Choose a slot: an empty one with a page; else a new one, if
        # a page is free; else the least recently used valid one that
        # this call has not used; else wait for one being filled. If none
        # is being filled either, the cache cannot hold every block this
        # call needs: E_NOMEM, rather than evict one and go round for ever.
        mv    a1, a0                   # a1: the block
        li    t3, 0                    # t3: the valid slot used longest ago
        li    t4, 0                    # t4: a slot with no page yet
        la    t1, bufs
        li    t2, NBUF
3:      lw    t0, BUF_PAGE(t1)
        bnez  t0, 4f
        mv    t4, t1
        j     6f
4:      lw    t0, BUF_STATE(t1)
        beqz  t0, buf_take             # empty, with a page: the best there is
        addi  t0, t0, -BUF_VALID
        bnez  t0, 6f                   # being filled
        lw    t0, BUF_USED(t1)
        lw    a0, PCB_BSTART(s0)
        bgt   t0, a0, 6f               # this very call needs it
        beqz  t3, 5f
        lw    a0, BUF_USED(t3)
        bge   t0, a0, 6f
5:      mv    t3, t1
6:      addi  t1, t1, BUF
        addi  t2, t2, -1
        bnez  t2, 3b
        beqz  t4, buf_evict
        lw    t0, free_count
        beqz  t0, buf_evict
        mv    t3, t4                   # a new slot: give it a page, which
        call  take_page                # the read fills whole
        sw    a0, BUF_PAGE(t3)
        j     7f
buf_evict:
        bnez  t3, 7f
        la    t1, bufs                 # nothing valid: wait for a slot
        li    t2, NBUF                 # being filled, if there is one
1:      lw    t0, BUF_STATE(t1)
        li    t4, BUF_FILLING
        beq   t0, t4, buf_wait
        addi  t1, t1, BUF
        addi  t2, t2, -1
        bnez  t2, 1b
        li    a0, E_NOMEM
        j     sys_return
buf_take:
        mv    t3, t1
7:      sw    a1, BUF_BLOCK(t3)        # t3: the slot, to fill with block a1
        li    t0, BUF_FILLING
        sw    t0, BUF_STATE(t3)
        sw    a1, PCB_DBLOCK(s0)
        lw    t0, BUF_PAGE(t3)
        sw    t0, PCB_DPAGE(s0)
        li    t0, BLOCK_READ
        sw    t0, PCB_DCMD(s0)
        li    t0, 1
        sw    t0, PCB_RETRY(s0)
        j     disk_queue
8:      li    a0, E_IO
        j     sys_return

# buf_wait: abandon the call until another's command for the cache ends.
buf_wait:
        li    t0, 1
        sw    t0, PCB_RETRY(s0)
        li    t0, ST_BUF
        sw    t0, PCB_STATE(s0)
        j     schedule

# buf_filled: the command of the process in s1 has read block PCB_DBLOCK
# into the cache, or failed, as a0 says. Keep the block, or give the slot
# up and end the process's call with E_IO rather than run it again.
# Clobbers t0..t4; keeps s1.
buf_filled:
        lw    t2, PCB_DBLOCK(s1)
        la    t1, bufs
        li    t3, NBUF
1:      lw    t0, BUF_STATE(t1)
        li    t4, BUF_FILLING
        bne   t0, t4, 2f
        lw    t0, BUF_BLOCK(t1)
        beq   t0, t2, 3f
2:      addi  t1, t1, BUF
        addi  t3, t3, -1
        bnez  t3, 1b
        ret                            # cannot happen: the slot was marked
3:      li    t0, BUF_VALID
        beqz  a0, 4f
        sw    a0, PCB_A0(s1)
        sw    zero, PCB_RETRY(s1)
        li    t0, BUF_EMPTY
4:      sw    t0, BUF_STATE(t1)
        ret

# buf_wake: a command for the cache has ended: every process waiting for
# one tries its call again. Clobbers t0..t5; keeps s1.
buf_wake:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    t5, procs
        li    t4, NPROC
1:      lw    t0, PCB_STATE(t5)
        li    t1, ST_BUF
        bne   t0, t1, 2f
        li    t0, ST_READY
        sw    t0, PCB_STATE(t5)
        call  wake_one
2:      addi  t5, t5, PCB_SIZE
        addi  t4, t4, -1
        bnez  t4, 1b
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# buf_forget: block a0 is being written past the cache (bwrite): drop a
# copy the cache holds. Clobbers t0..t2.
buf_forget:
        la    t1, bufs
        li    t2, NBUF
1:      lw    t0, BUF_STATE(t1)
        addi  t0, t0, -BUF_VALID
        bnez  t0, 2f
        lw    t0, BUF_BLOCK(t1)
        bne   t0, a0, 2f
        sw    zero, BUF_STATE(t1)      # BUF_EMPTY
2:      addi  t1, t1, BUF
        addi  t2, t2, -1
        bnez  t2, 1b
        ret
        .nocompress
