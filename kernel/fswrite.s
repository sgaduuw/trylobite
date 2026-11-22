# The filesystem's calls that change it: write, unlink, mkdir and rmdir,
# and the making and emptying of files for open (fs.s). Each gathers
# every block it will change first, with bgetw, and bnew for a block it
# allocates, and so may be abandoned and run again up to there. Then it
# changes them all, marks them dirty and lets the cache write them back
# (cache.s); nothing after that point can abandon the call, since every
# block it touches is in the cache and was used by this call.
#
# The map and the inode table are read and changed in place in block 0
# and block 1; a call allocates the lowest free block or inode it finds,
# and marks it used only when it changes everything else.

        .compress
# write(fd, buffer, n): copy up to n trytes from the buffer to the file
# at the position (its end, with O_APPEND), no further than the end of
# the block the position is in, and move the position past them: how
# many. A block not there yet is allocated, and the indirect block too.
sys_write:
        addi  sp, sp, -9               # 0: the position in its block,
        call  sua_on                   # 3: 1 if the indirect block is new,
        call  fdget                    # 6: 1 if the data block is new
        mv    s2, a0                   # s2: the descriptor
        lw    t0, FD_FLAGS(s2)
        li    t1, 3
        rem   t0, t0, t1
        beqz  t0, fs_badf              # opened for reading only
        lw    s3, PCB_A3(s0)           # s3: how many to copy
        bltz  s3, fs_inval
        lw    a0, PCB_A2(s0)
        mv    a1, s3
        call  urange
        lw    s4, FD_INO(s2)           # s4: the inode
        li    a0, FS_INODE_BLOCK
        call  bgetw
        mv    a0, s4
        call  iget
        lw    s5, FD_POS(s2)           # s5: where to write
        lw    t0, FD_FLAGS(s2)
        li    t1, O_APPEND
        div   t0, t0, t1
        beqz  t0, 1f
        lw    s5, I_SIZE(a0)
1:      beqz  s3, fs_none
        li    t2, PAGE
        div   s6, s5, t2               # s6: the file's block to write in
        rem   t1, s5, t2
        sw    t1, 0(sp)
        sub   t1, t2, t1               # what is left of the block
        bge   t1, s3, 2f
        mv    s3, t1
2:      li    t0, NDIRECT + PAGE / 3
        bge   s6, t0, 9f               # past what a file can hold
        sw    zero, 3(sp)
        sw    zero, 6(sp)
        li    s8, NO_BLOCK             # s8: the indirect block, if it counts
        li    t0, NDIRECT
        bge   s6, t0, 3f
        li    t0, 3
        mul   t0, s6, t0
        add   t0, a0, t0
        lw    s7, I_DIRECT(t0)         # s7: the data block, or NO_BLOCK
        j     5f
3:      lw    s8, I_INDIRECT(a0)
        li    s7, NO_BLOCK
        bnez  s8, 4f
        li    t0, 1                    # no indirect block yet
        sw    t0, 3(sp)
        li    a0, 0
        call  balloc
        mv    s8, a0
        call  bnew
        j     5f
4:      mv    a0, s8
        call  bgetw
        addi  t0, s6, -NDIRECT
        li    t1, 3
        mul   t0, t0, t1
        add   t0, a0, t0
        lw    s7, BLOCK_W0(t0)
5:      bnez  s7, 6f
        li    t0, 1                    # no data block yet
        sw    t0, 6(sp)
        li    a0, 0
        lw    t0, 3(sp)
        beqz  t0, 0f
        addi  a0, s8, 1                # past a new indirect block
0:      call  balloc
        mv    s7, a0
        call  bnew
        j     7f
6:      mv    a0, s7
        call  bgetw

        # Every block is here: change them.
7:      lw    t0, 3(sp)
        lw    t1, 6(sp)
        add   t0, t0, t1
        beqz  t0, 8f                   # nothing allocated
        li    a0, 0
        call  bget
        li    t1, MAP_USED
        add   t0, a0, s7
        st    t1, FS_MAP(t0)
        lw    t0, 3(sp)
        beqz  t0, 0f
        add   t0, a0, s8
        st    t1, FS_MAP(t0)
0:      li    a0, 0
        call  bdirty
8:      mv    a0, s4
        call  iget
        li    t0, NDIRECT
        bge   s6, t0, 1f
        li    t0, 3
        mul   t0, s6, t0
        add   t0, a0, t0
        sw    s7, I_DIRECT(t0)
        j     2f
1:      sw    s8, I_INDIRECT(a0)
        mv    a0, s8
        call  bget
        addi  t0, s6, -NDIRECT
        li    t1, 3
        mul   t0, t0, t1
        add   t0, a0, t0
        sw    s7, BLOCK_W0(t0)
        mv    a0, s8
        call  bdirty
2:      mv    a0, s7
        call  bget
        lw    t0, 0(sp)
        add   t2, a0, t0
        addi  t2, t2, BLOCK_T0         # t2: where the trytes go
        lw    t3, PCB_A2(s0)           # t3: where they come from
        mv    t1, s3
3:      lt    t0, 0(t3)
        st    t0, 0(t2)
        addi  t2, t2, 1
        addi  t3, t3, 1
        addi  t1, t1, -1
        bnez  t1, 3b
        mv    a0, s7
        call  bdirty
        mv    a0, s4
        call  iget
        add   s5, s5, s3
        lw    t0, I_SIZE(a0)
        bge   t0, s5, 4f
        sw    s5, I_SIZE(a0)           # it grew
4:      sw    s5, FD_POS(s2)
        li    a0, FS_INODE_BLOCK
        call  bdirty
        call  disk_kick
        mv    a0, s3
        j     sys_return
9:      li    a0, E_FBIG
        j     sys_return

# unlink(path): remove a file's name, and the file once it has no other.
# A directory is E_ISDIR (rmdir removes those), and a file some process
# has open is E_BUSY, since a descriptor names the inode.
sys_unlink:
        call  fs_enter
        lw    a0, PCB_A1(s0)
        call  namei_parent
        beqz  a1, fs_isdir             # the root
        mv    s8, a0                   # s8: the directory
        call  dot_check
        mv    a0, s8
        call  dirfind
        beqz  a0, fs_noent
        mv    s3, a0                   # s3: the entry
        lw    s4, D_INO(s3)            # s4: the file
        mv    a0, s4
        call  iget
        lw    t0, I_TYPE(a0)
        li    t1, T_DIR
        beq   t0, t1, fs_isdir
        mv    a0, s4
        call  ino_open
        li    a0, FS_INODE_BLOCK
        call  bgetw
        mv    a0, s4
        call  trunc_prep               # in case this is its last name

        mv    a0, s3                   # change: the entry goes
        li    a1, NO_INO
        la    a2, knone
        call  dirent_set
        mv    a0, s8
        call  dir_dirty
        mv    a0, s4
        call  iget
        lw    t0, I_LINKS(a0)
        addi  t0, t0, -1
        sw    t0, I_LINKS(a0)
        bgtz  t0, 1f
        mv    a0, s4                   # no name left: neither is the file
        call  ifree
1:      li    a0, FS_INODE_BLOCK
        call  bdirty
        call  disk_kick
        li    a0, 0
        j     sys_return

# mkdir(path): a new, empty directory, holding . and ..
sys_mkdir:
        call  fs_enter
        lw    a0, PCB_A1(s0)
        call  namei_parent
        beqz  a1, fs_exist             # the root
        mv    s8, a0                   # s8: the parent
        call  name_ok
        mv    a0, s8
        call  dirfind
        bnez  a0, fs_exist
        beqz  a1, fs_nospc             # the parent is full
        mv    s2, a1                   # s2: the entry to use
        mv    s3, a2                   # s3: 1 if that grows the parent
        call  ialloc
        mv    s4, a0                   # s4: the new directory's inode
        li    a0, 0
        call  balloc
        mv    s5, a0                   # s5: its block
        call  bnew

        li    a0, 0                    # change
        call  bget
        add   t0, a0, s5
        li    t1, MAP_USED
        st    t1, FS_MAP(t0)
        li    a0, 0
        call  bdirty
        mv    a0, s4
        call  iget
        call  inode_clear
        li    t0, T_DIR
        sw    t0, I_TYPE(a0)
        li    t0, 2                    # its name and its .
        sw    t0, I_LINKS(a0)
        li    t0, 2 * DIRENT
        sw    t0, I_SIZE(a0)
        sw    s5, I_DIRECT(a0)
        mv    a0, s5
        call  bget
        addi  a0, a0, BLOCK_W0
        mv    a1, s4
        la    a2, kdot
        call  dirent_set
        mv    a0, s5
        call  bget
        addi  a0, a0, BLOCK_W0 + DIRENT
        mv    a1, s8
        la    a2, kdotdot
        call  dirent_set
        mv    a0, s5
        call  bdirty
        mv    a0, s2
        mv    a1, s4
        la    a2, kname
        call  dirent_set
        mv    a0, s8
        call  iget
        lw    t0, I_LINKS(a0)          # the new directory's ..
        addi  t0, t0, 1
        sw    t0, I_LINKS(a0)
        beqz  s3, 1f
        lw    t0, I_SIZE(a0)
        addi  t0, t0, DIRENT
        sw    t0, I_SIZE(a0)
1:      mv    a0, s8
        call  dir_dirty
        li    a0, FS_INODE_BLOCK
        call  bdirty
        call  disk_kick
        li    a0, 0
        j     sys_return

# rmdir(path): remove a directory holding nothing but . and .. . One a
# process has open is E_BUSY, as is the root.
sys_rmdir:
        call  fs_enter
        lw    a0, PCB_A1(s0)
        call  namei_parent
        beqz  a1, fs_busy              # the root
        mv    s8, a0                   # s8: the parent
        call  dot_check
        mv    a0, s8
        call  dirfind
        beqz  a0, fs_noent
        mv    s3, a0                   # s3: the entry
        lw    s4, D_INO(s3)            # s4: the directory to go
        mv    a0, s4
        call  iget
        lw    t0, I_TYPE(a0)
        li    t1, T_DIR
        bne   t0, t1, fs_notdir
        lw    s5, I_SIZE(a0)
        li    t1, DIRENT
        div   s5, s5, t1               # s5: its entries
        li    t1, DIRENTS
        bgt   s5, t1, fs_eio
        lw    a0, I_DIRECT(a0)
        beqz  a0, fs_eio
        call  bget
        addi  s6, a0, BLOCK_W0         # s6: the entry looked at
1:      beqz  s5, 3f
        lw    t0, D_INO(s6)
        beqz  t0, 2f
        addi  t2, s6, D_NAME           # only . and .. may be in use
        li    t1, '.'
        lt    t0, 0(t2)
        bne   t0, t1, fs_notempty
        lt    t0, 1(t2)
        beqz  t0, 2f
        bne   t0, t1, fs_notempty
        lt    t0, 2(t2)
        bnez  t0, fs_notempty
2:      addi  s6, s6, DIRENT
        addi  s5, s5, -1
        j     1b
3:      mv    a0, s4
        call  ino_open
        li    a0, FS_INODE_BLOCK
        call  bgetw
        mv    a0, s4
        call  trunc_prep

        mv    a0, s3                   # change: the entry goes
        li    a1, NO_INO
        la    a2, knone
        call  dirent_set
        mv    a0, s8
        call  dir_dirty
        mv    a0, s4
        call  ifree
        mv    a0, s8
        call  iget
        lw    t0, I_LINKS(a0)          # its .. named the parent
        addi  t0, t0, -1
        sw    t0, I_LINKS(a0)
        li    a0, FS_INODE_BLOCK
        call  bdirty
        call  disk_kick
        li    a0, 0
        j     sys_return

# --- helpers ---------------------------------------------------------------------

# creat: for open with O_CREAT: a0 = the inode named kname in directory
# a0 and a1 = 0, if there is one; else a new, empty file of that name,
# and a1 = -1. Clobbers a2, t0..t5 and s2..s7; keeps s8.
creat:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)                # the directory
        call  dirfind
        beqz  a0, 1f
        lw    a0, D_INO(a0)
        li    a1, 0
        j     9f
1:      beqz  a1, fs_nospc             # the directory is full
        mv    s2, a1                   # s2: the entry to use
        mv    s3, a2                   # s3: 1 if that grows the directory
        call  name_ok
        call  ialloc
        mv    s4, a0                   # s4: the new file

        mv    a0, s4                   # change
        call  iget
        call  inode_clear
        li    t0, T_FILE
        sw    t0, I_TYPE(a0)
        li    t0, 1
        sw    t0, I_LINKS(a0)
        mv    a0, s2
        mv    a1, s4
        la    a2, kname
        call  dirent_set
        beqz  s3, 2f
        lw    a0, 3(sp)
        call  iget
        lw    t0, I_SIZE(a0)
        addi  t0, t0, DIRENT
        sw    t0, I_SIZE(a0)
2:      lw    a0, 3(sp)
        call  dir_dirty
        li    a0, FS_INODE_BLOCK
        call  bdirty
        call  disk_kick
        mv    a0, s4
        li    a1, -1
9:      lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# dirfind: look kname up in directory a0, whose block is gathered to be
# changed (bgetw). a0 = the address of its entry in the cache, or 0; a1
# = an entry a new name could take, or 0 when the directory is full,
# and a2 = 1 if that entry is past the directory's end. Ends the call
# with E_NOTDIR if a0 is not a directory. Clobbers t0..t5 and s6.
dirfind:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  iget
        lw    t0, I_TYPE(a0)
        li    t1, T_DIR
        bne   t0, t1, fs_notdir
        lw    s6, I_SIZE(a0)
        li    t1, DIRENT
        div   s6, s6, t1               # s6: its entries
        li    t1, DIRENTS
        bgt   s6, t1, fs_eio
        lw    a0, I_DIRECT(a0)
        beqz  a0, fs_eio               # every directory has . and ..
        call  bgetw
        addi  t2, a0, BLOCK_W0         # t2: the entry looked at
        li    a1, 0
        li    t5, 0                    # t5: its number
1:      bge   t5, s6, 5f
        lw    t0, D_INO(t2)
        bnez  t0, 2f
        bnez  a1, 4f                   # unused: the first can take a name
        mv    a1, t2
        j     4f
2:      addi  t3, t2, D_NAME
        la    t4, kname
3:      lt    t0, 0(t3)
        lt    t1, 0(t4)
        bne   t0, t1, 4f
        addi  t3, t3, 1
        addi  t4, t4, 1
        bnez  t0, 3b
        mv    a0, t2                   # the same, to the end
        j     9f
4:      addi  t2, t2, DIRENT
        addi  t5, t5, 1
        j     1b
5:      li    a0, 0
        li    a2, 0
        bnez  a1, 9f
        li    t0, DIRENTS
        bge   s6, t0, 9f               # full: a1 stays 0
        mv    a1, t2                   # the entry just past the end
        li    a2, 1
9:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# dot_check: E_INVAL ends the call if kname is . or .., which every
# directory has and none may lose or gain. Clobbers t0, t1.
dot_check:
        la    t1, kname
        lt    t0, 0(t1)
        addi  t0, t0, -'.'
        bnez  t0, 9f
        lt    t0, 1(t1)
        beqz  t0, fs_inval             # .
        addi  t0, t0, -'.'
        bnez  t0, 9f
        lt    t0, 2(t1)
        beqz  t0, fs_inval             # ..
9:      ret

# name_ok: E_INVAL ends the call unless kname may be a new name: not .
# or .., and no space or control character (namei keeps out /).
# Clobbers t0..t2.
name_ok:
        mv    t2, ra
        call  dot_check
        mv    ra, t2
        la    t1, kname
1:      lt    t0, 0(t1)
        beqz  t0, 9f
        li    t2, ' '
        ble   t0, t2, fs_inval
        addi  t1, t1, 1
        j     1b
9:      ret

# ialloc: a0 = the lowest free inode, the inode table gathered to be
# changed; E_NOSPC when there is none. Clobbers a1, t0..t5.
ialloc:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    a0, FS_INODE_BLOCK
        call  bgetw
        addi  t1, a0, BLOCK_W0 + 2 * INODE
        li    a0, ROOT_INO + 1
1:      li    t0, FS_INODES
        bge   a0, t0, fs_nospc
        lw    t0, I_TYPE(t1)
        beqz  t0, 2f                   # T_FREE
        addi  t1, t1, INODE
        addi  a0, a0, 1
        j     1b
2:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# balloc: a0 = the lowest free block from a0 on, block 0 gathered to be
# changed; E_NOSPC when there is none. The map is not changed: the
# caller marks it, and asks for a second block from past the first.
# Clobbers a1, t0..t5.
balloc:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        li    a0, 0
        call  bgetw
        lw    t2, 3(sp)                # t2: the block looked at
        li    t0, FS_INODE_BLOCK + 1
        bge   t2, t0, 1f
        mv    t2, t0
1:      lw    t3, FS_HEAD_BLOCKS(a0)   # t3: where the filesystem ends
        li    t0, V_DISK
        lw    t0, DISK_BLOCKS(t0)
        ble   t3, t0, 2f
        mv    t3, t0                   # or the disk, if that is shorter
2:      bge   t2, t3, fs_nospc
        add   t0, a0, t2
        lt    t1, FS_MAP(t0)
        beqz  t1, 3f                   # MAP_FREE
        addi  t2, t2, 1
        j     2b
3:      mv    a0, t2
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# trunc_prep: gather what itrunc and ifree need for inode a0: block 0,
# the inode table, and its indirect block. Clobbers a0, a1, t0..t5.
trunc_prep:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        li    a0, 0
        call  bgetw
        li    a0, FS_INODE_BLOCK
        call  bgetw
        lw    a0, 3(sp)
        call  iget
        lw    a0, I_INDIRECT(a0)
        beqz  a0, 1f
        call  bget                     # only read
1:      lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# itrunc: empty inode a0: free each block it holds in the map, and clear
# its size and block numbers; trunc_prep gathered what it needs. Marks
# block 0 and the inode table dirty. Clobbers a0, a1, a2, t0..t5.
itrunc:
        addi  sp, sp, -9
        sw    ra, 0(sp)
        sw    a0, 3(sp)                # 3: the inode, 6: block 0
        li    a0, 0
        call  bget
        sw    a0, 6(sp)
        lw    a0, 3(sp)
        call  iget
        mv    a2, a0                   # a2: the inode
        lw    a1, 6(sp)
        addi  t1, a2, I_DIRECT
        li    t2, NDIRECT
1:      lw    t0, 0(t1)                # each direct block
        call  map_free
        sw    zero, 0(t1)
        addi  t1, t1, 3
        addi  t2, t2, -1
        bnez  t2, 1b
        sw    zero, I_SIZE(a2)
        lw    a0, I_INDIRECT(a2)
        beqz  a0, 3f
        sw    zero, I_INDIRECT(a2)
        mv    t0, a0
        call  map_free
        call  bget                     # its numbers, still as they were
        lw    a1, 6(sp)
        addi  t1, a0, BLOCK_W0
        li    t2, PAGE / 3
2:      lw    t0, 0(t1)
        call  map_free
        addi  t1, t1, 3
        addi  t2, t2, -1
        bnez  t2, 2b
3:      li    a0, 0
        call  bdirty
        li    a0, FS_INODE_BLOCK
        call  bdirty
        lw    ra, 0(sp)
        addi  sp, sp, 9
        ret

# map_free: mark block t0 free in the map of block 0 at a1. NO_BLOCK, and
# a number past the map, which only a damaged filesystem holds, are left
# alone. Clobbers t0, t3.
map_free:
        blez  t0, 9f
        li    t3, FS_MAX_BLOCKS
        bge   t0, t3, 9f
        add   t0, a1, t0
        st    zero, FS_MAP(t0)         # MAP_FREE
9:      ret

# ifree: itrunc inode a0, then mark it unused. Clobbers as itrunc.
ifree:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        call  itrunc
        lw    a0, 3(sp)
        call  iget
        call  inode_clear
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# inode_clear: zero the inode at a0: T_FREE, no links, no blocks.
# Clobbers t0, t1.
inode_clear:
        mv    t0, a0
        addi  t1, a0, INODE - 3
1:      sw    zero, 0(t0)
        addi  t0, t0, 3
        ble   t0, t1, 1b
        ret

# ino_open: E_BUSY ends the call if a live process has inode a0 open.
# Clobbers t0..t4.
ino_open:
        la    t1, procs
        li    t2, NPROC
1:      lw    t0, PCB_STATE(t1)
        beqz  t0, 4f                   # a free slot
        li    t3, ST_ZOMBIE
        beq   t0, t3, 4f               # ended: its descriptors are gone
        addi  t3, t1, PCB_FDS
        li    t4, NFD
2:      lw    t0, FD_INO(t3)
        beq   t0, a0, fs_busy
        addi  t3, t3, FD
        addi  t4, t4, -1
        bnez  t4, 2b
4:      addi  t1, t1, PCB_SIZE
        addi  t2, t2, -1
        bnez  t2, 1b
        ret

# dirent_set: make the directory entry at a0 name inode a1 with the
# string at a2, zero-padded. Clobbers a2, t0..t2.
dirent_set:
        sw    a1, D_INO(a0)
        addi  t0, a0, D_NAME
        li    t1, NAME_MAX + 1
1:      lt    t2, 0(a2)
        beqz  t2, 2f
        st    t2, 0(t0)
        addi  t0, t0, 1
        addi  a2, a2, 1
        addi  t1, t1, -1
        j     1b
2:      st    zero, 0(t0)
        addi  t0, t0, 1
        addi  t1, t1, -1
        bgtz  t1, 2b
        ret

# dir_dirty: mark directory a0's block dirty. Clobbers a0, a1, t0..t5.
dir_dirty:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  iget
        lw    a0, I_DIRECT(a0)
        call  bdirty
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

fs_exist:
        li    a0, E_EXIST
        j     sys_return
fs_nospc:
        li    a0, E_NOSPC
        j     sys_return
fs_notempty:
        li    a0, E_NOTEMPTY
        j     sys_return
fs_busy:
        li    a0, E_BUSY
        j     sys_return
        .nocompress
