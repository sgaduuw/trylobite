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
# A call that changes blocks gathers them first with bgetw (and bnew for
# a block it allocates), changes them all at once and marks them dirty
# (bdirty); disk_kick then writes dirty blocks back one at a time
# whenever the disk has nothing else to do, and the kernel does not
# power off before they are all written (pick). A block being written
# back is not changed until it is done, so the disk gets one version.
#
# Slots are reused least recently used first, clean ones only. A slot
# being filled is left alone, and a hit never evicts, so an address bget
# returned stays good until the call ends or abandons itself.

        .compress
# bget: a0 = the kernel address of block a0's centre, from the cache,
# and a1 = its slot. A block that is not there is read, and the call is
# abandoned and run again when it is (not returning). A block past the
# disk's end, which only a damaged filesystem names, ends the call with
# E_IO; no slot to read it into, with E_NOMEM. Clobbers a0, a1 and
# t0..t5; keeps s1..s8.
bget:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  buf_find                 # t1: its slot, or 0
        beqz  t1, 1f
        li    t0, BUF_FILLING
        beq   t3, t0, buf_wait         # on its way: wait with the others
        lw    ra, 0(sp)
        addi  sp, sp, 3
        mv    a1, t1
        lw    a0, BUF_PAGE(t1)
        j     kva
1:      call  buf_slot                 # t3: a slot for it
        sw    a1, BUF_BLOCK(t3)
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

# bgetw: bget, for a block the call will change: it waits while the
# block is being written back. Clobbers as bget.
bgetw:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  bget
        lw    t0, BUF_STATE(a1)
        li    t1, BUF_WRITING
        beq   t0, t1, buf_wait
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# bnew: a0 = the kernel address of free block a0's centre, in a slot of
# the cache cleared to zeros without reading the disk, for a call about
# to allocate it; a1 = the slot. If the call is abandoned, the block is
# still free, and what a free block holds does not matter. Clobbers as
# bget.
bnew:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  buf_find
        beqz  t1, 1f
        li    t0, BUF_FILLING          # an old copy: wait until it is
        beq   t3, t0, buf_wait         # neither filling nor being written
        li    t0, BUF_WRITING
        beq   t3, t0, buf_wait
        mv    t3, t1
        j     2f
1:      call  buf_slot                 # t3: a slot for it
        sw    a1, BUF_BLOCK(t3)
        li    t0, BUF_VALID
        sw    t0, BUF_STATE(t3)
2:      lw    t0, buf_clock
        sw    t0, BUF_USED(t3)
        lw    a0, BUF_PAGE(t3)
        call  kva
        addi  t1, a0, BLOCK_W0
        addi  t2, a0, -BLOCK_W0
3:      sw    zero, 0(t1)
        addi  t1, t1, 3
        ble   t1, t2, 3b
        mv    a1, t3
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# bdirty: block a0, in the cache, now differs from the disk. The call
# has bgetw or bnew'd it, so it is there and not being written.
# Clobbers t0..t2.
bdirty:
        la    t1, bufs
        li    t2, NBUF
1:      lw    t0, BUF_BLOCK(t1)
        bne   t0, a0, 2f
        lw    t0, BUF_STATE(t1)
        beqz  t0, 2f
        li    t0, BUF_DIRTY
        sw    t0, BUF_STATE(t1)
        ret
2:      addi  t1, t1, BUF
        addi  t2, t2, -1
        bnez  t2, 1b
        ret

# buf_find: t1 = the slot holding block a0, or 0, and t3 = its state;
# a1 = a0, and the clock moves on, the slot found marked used now. Ends
# the call with E_IO for a block past the disk's end. Clobbers t0..t5.
buf_find:
        bltz  a0, 8f
        li    t0, V_DISK
        lw    t0, DISK_BLOCKS(t0)
        bge   a0, t0, 8f
        mv    a1, a0
        lw    t5, buf_clock
        addi  t5, t5, 1
        sw    t5, buf_clock            # t5: now
        la    t1, bufs
        li    t2, NBUF
1:      lw    t3, BUF_STATE(t1)
        beqz  t3, 2f                   # BUF_EMPTY
        lw    t4, BUF_BLOCK(t1)
        bne   t4, a0, 2f
        sw    t5, BUF_USED(t1)
        ret
2:      addi  t1, t1, BUF
        addi  t2, t2, -1
        bnez  t2, 1b
        li    t1, 0
        ret
8:      li    a0, E_IO
        j     sys_return

# buf_slot: t3 = a slot to put another block in, marked used now: an
# empty one with a page; else a new one, if a page is free; else the
# clean one used longest ago that this call has not used. Else, if a
# dirty one could be written back, or one is being filled or written,
# wait for it, abandoning the call. If none is, the cache cannot hold
# every block this call needs: E_NOMEM, rather than evict one and go
# round for ever. Keeps a1. Clobbers a0, t0..t5.
buf_slot:
        li    t3, 0                    # t3: the clean slot used longest ago
        li    t4, 0                    # t4: a slot with no page yet
        li    t5, 0                    # t5: 1 if one is worth waiting for
        la    t1, bufs
        li    t2, NBUF
1:      lw    t0, BUF_PAGE(t1)
        bnez  t0, 2f
        mv    t4, t1
        j     5f
2:      lw    t0, BUF_STATE(t1)
        beqz  t0, 7f                   # empty, with a page: the best there is
        addi  t0, t0, -BUF_VALID
        beqz  t0, 3f
        li    t5, 1                    # filling, dirty or being written:
        j     5f                       # it will do once it is clean
3:      lw    t0, BUF_USED(t1)
        lw    a0, PCB_BSTART(s0)
        bgt   t0, a0, 5f               # this very call needs it
        beqz  t3, 4f
        lw    a0, BUF_USED(t3)
        bge   t0, a0, 5f
4:      mv    t3, t1
5:      addi  t1, t1, BUF
        addi  t2, t2, -1
        bnez  t2, 1b
        beqz  t4, 6f
        lw    t0, free_count
        beqz  t0, 6f
        mv    t3, t4                   # a new slot: give it a page
        mv    t5, ra
        call  take_page
        sw    a0, BUF_PAGE(t3)
        mv    ra, t5
        j     8f
6:      bnez  t3, 8f
        beqz  t5, 9f
        call  disk_kick                # if a dirty one waits, write it
        j     buf_wait
7:      mv    t3, t1
8:      lw    t0, buf_clock
        sw    t0, BUF_USED(t3)
        ret
9:      li    a0, E_NOMEM
        j     sys_return

# disk_kick: if the disk is free and a block in the cache is dirty,
# start writing it back. Clobbers t0..t2.
disk_kick:
        lw    t0, disk_user
        bnez  t0, 9f                   # busy: disk_irq comes back here
        la    t1, bufs
        li    t2, NBUF
1:      lw    t0, BUF_STATE(t1)
        addi  t0, t0, -BUF_DIRTY
        beqz  t0, 2f
        addi  t1, t1, BUF
        addi  t2, t2, -1
        bnez  t2, 1b
9:      ret
2:      li    t0, BUF_WRITING
        sw    t0, BUF_STATE(t1)
        sw    t1, flush_slot
        li    t0, DISK_FLUSH
        sw    t0, disk_user
        lw    t2, BUF_PAGE(t1)
        la    t0, disk_list
        sw    t2, 0(t0)
        li    t2, KOFF
        add   t2, t0, t2               # the list's physical address
        li    t0, V_DISK
        sw    t2, DISK_LIST(t0)
        lw    t2, BUF_BLOCK(t1)
        sw    t2, DISK_BLOCK(t0)
        li    t2, 1
        sw    t2, DISK_COUNT(t0)
        li    t2, BLOCK_WRITE
        sw    t2, DISK_COMMAND(t0)
        ret

# buf_written: the write-back disk_kick started has ended: the block is
# clean. One the disk refused is dropped as clean too, since retrying
# would keep the kernel from powering off; the disk only refuses what
# the driver's checks let through, which is nothing. Clobbers t0, t1.
buf_written:
        lw    t1, flush_slot
        li    t0, BUF_VALID
        sw    t0, BUF_STATE(t1)
        ret

# buf_busy: a0 = 1 while the disk is working or a block waits to be
# written back (starting it), else 0: the kernel may not power off yet.
# Clobbers t0..t2.
buf_busy:
        li    a0, 1
        lw    t0, disk_user
        bnez  t0, 9f
        mv    a0, ra
        call  disk_kick
        mv    ra, a0
        li    a0, 1
        lw    t0, disk_user
        bnez  t0, 9f
        li    a0, 0
9:      ret

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
# copy the cache holds, clean or dirty; the bwrite wins. One being filled
# or written back is left to finish. Clobbers t0..t2.
buf_forget:
        la    t1, bufs
        li    t2, NBUF
1:      lw    t0, BUF_STATE(t1)
        addi  t0, t0, -BUF_VALID
        beqz  t0, 3f
        addi  t0, t0, BUF_VALID - BUF_DIRTY
        bnez  t0, 2f
3:        lw    t0, BUF_BLOCK(t1)
        bne   t0, a0, 2f
        sw    zero, BUF_STATE(t1)      # BUF_EMPTY
2:      addi  t1, t1, BUF
        addi  t2, t2, -1
        bnez  t2, 1b
        ret
        .nocompress
