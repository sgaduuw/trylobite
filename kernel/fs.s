# The filesystem's system calls (docs/filesystem.md): open, close, read,
# lseek, readdir, stat and spawnf. They read blocks through the cache
# (cache.s), so each may be abandoned at a bget and run again from the
# start; none changes anything before its last bget. A call that fails
# jumps to sys_return with the reason, from wherever it found it.
#
# s0 is the caller's record, as everywhere; the calls keep their own
# values in s2..s6, which bget keeps.

        .compress
# open(path, flags): the lowest free descriptor, at the start of the
# file or directory path names.
sys_open:
        call  fs_enter
        lw    t0, PCB_A2(s0)
        li    t1, O_RDONLY
        bne   t0, t1, fs_inval
        lw    a0, PCB_A1(s0)
        call  namei                    # a0: the inode
        addi  t1, s0, PCB_FDS          # t1: the descriptor tried
        li    t2, 0                    # t2: its number
1:      lw    t0, FD_INO(t1)
        beqz  t0, 2f
        addi  t1, t1, FD
        addi  t2, t2, 1
        li    t0, NFD
        blt   t2, t0, 1b
        li    a0, E_MFILE
        j     sys_return
2:      sw    a0, FD_INO(t1)
        sw    zero, FD_POS(t1)
        lw    t0, PCB_A2(s0)
        sw    t0, FD_FLAGS(t1)
        mv    a0, t2
        j     sys_return

# close(fd)
sys_close:
        call  fdget
        sw    zero, FD_INO(a0)
        li    a0, 0
        j     sys_return

# read(fd, buffer, n): copy up to n trytes from the file to the buffer,
# no further than the end of the file or of the block the position is
# in, and move the position past them. A hole reads as zeros.
sys_read:
        call  sua_on
        call  fdget
        mv    s2, a0                   # s2: the descriptor
        lw    s3, PCB_A3(s0)           # s3: how many to copy
        bltz  s3, fs_inval
        lw    a0, PCB_A2(s0)
        mv    a1, s3
        call  urange
        lw    a0, FD_INO(s2)
        call  iget
        mv    s4, a0                   # s4: the inode
        lw    t0, I_TYPE(s4)
        li    t1, T_DIR
        beq   t0, t1, fs_isdir
        lw    t0, I_SIZE(s4)
        lw    t1, FD_POS(s2)
        sub   t0, t0, t1               # what is left of the file
        bge   s3, t0, 1f
        mv    t0, s3
1:      li    t2, PAGE
        rem   s5, t1, t2               # s5: the position within its block
        sub   t3, t2, s5               # what is left of the block
        bge   t0, t3, 2f
        mv    t3, t0
2:      mv    s3, t3                   # s3: how many, to copy now
        blez  s3, fs_none              # the end, or nothing asked
        div   a1, t1, t2
        mv    a0, s4
        call  bmap
        lw    s6, PCB_A2(s0)           # s6: where to
        mv    t1, s3
        beqz  a0, 4f                   # NO_BLOCK: a hole
        call  bget
        add   t2, a0, s5
        addi  t2, t2, BLOCK_T0         # t2: the first tryte to copy
        mv    t1, s3
3:      lt    t0, 0(t2)
        st    t0, 0(s6)
        addi  t2, t2, 1
        addi  s6, s6, 1
        addi  t1, t1, -1
        bnez  t1, 3b
        j     5f
4:      st    zero, 0(s6)
        addi  s6, s6, 1
        addi  t1, t1, -1
        bnez  t1, 4b
5:      lw    t0, FD_POS(s2)
        add   t0, t0, s3
        sw    t0, FD_POS(s2)
        mv    a0, s3
        j     sys_return

# lseek(fd, offset, whence): the position, set from the start, where it
# is or the end. It may pass the end of the file, but not its start.
sys_lseek:
        call  fdget
        mv    s2, a0                   # s2: the descriptor
        lw    t2, PCB_A3(s0)
        li    t1, 0                    # SEEK_SET: from 0
        li    t0, SEEK_SET
        beq   t2, t0, 2f
        lw    t1, FD_POS(s2)
        li    t0, SEEK_CUR
        beq   t2, t0, 2f
        li    t0, SEEK_END
        bne   t2, t0, fs_inval
        lw    a0, FD_INO(s2)
        call  iget
        lw    t1, I_SIZE(a0)
2:      lw    t0, PCB_A2(s0)
        add   a0, t0, t1
        bltz  a0, fs_inval
        sw    a0, FD_POS(s2)
        j     sys_return

# readdir(fd, buffer): the next entry in use of a directory: its name to
# the buffer, NAME_MAX + 1 trytes, and its inode in a0; or 0 at the end.
# The position counts DIRENT trytes per entry, used or not.
sys_readdir:
        call  sua_on
        call  fdget
        mv    s2, a0                   # s2: the descriptor
        lw    a0, PCB_A2(s0)
        li    a1, NAME_MAX + 1
        call  urange
        lw    a0, FD_INO(s2)
        call  iget
        lw    t0, I_TYPE(a0)
        li    t1, T_DIR
        bne   t0, t1, fs_notdir
        lw    s3, I_SIZE(a0)
        li    t1, DIRENT
        div   s3, s3, t1               # s3: its entries, in one block
        li    t0, DIRENTS
        bgt   s3, t0, fs_eio
        lw    s4, FD_POS(s2)
        div   s4, s4, t1               # s4: the next one to look at
        bge   s4, s3, fs_none
        lw    a0, I_DIRECT(a0)
        beqz  a0, fs_eio               # entries but no block
        call  bget
        addi  s5, a0, BLOCK_W0         # s5: its first entry
1:      bge   s4, s3, fs_none
        li    t0, DIRENT
        mul   t1, s4, t0
        add   t1, t1, s5               # t1: entry s4
        addi  s4, s4, 1
        lw    t2, D_INO(t1)
        beqz  t2, 1b                   # unused
        lw    t3, PCB_A2(s0)
        addi  t1, t1, D_NAME
        li    t4, NAME_MAX
2:      lt    t0, 0(t1)
        st    t0, 0(t3)
        addi  t1, t1, 1
        addi  t3, t3, 1
        addi  t4, t4, -1
        bnez  t4, 2b
        st    zero, 0(t3)              # ended, whatever the disk says
        li    t0, DIRENT
        mul   t0, s4, t0
        sw    t0, FD_POS(s2)
        mv    a0, t2
        j     sys_return

# stat(path, buffer): what path names, as the ST_ words at the buffer.
sys_stat:
        call  fs_enter
        lw    a0, PCB_A2(s0)
        li    t0, 3
        rem   t0, a0, t0
        bnez  t0, fs_fault             # words must be aligned
        addi  a0, a0, ST_INO - 1
        li    a1, STAT
        call  urange
        lw    a0, PCB_A1(s0)
        call  namei
        mv    s2, a0                   # s2: the inode's number
        call  iget
        lw    t1, PCB_A2(s0)
        sw    s2, ST_INO(t1)
        lw    t0, I_TYPE(a0)
        sw    t0, ST_TYPE(t1)
        lw    t0, I_LINKS(a0)
        sw    t0, ST_LINKS(t1)
        lw    t0, I_SIZE(a0)
        sw    t0, ST_SIZE(t1)
        li    a0, 0
        j     sys_return

# spawnf(path): start the program file path names, as spawnw starts one
# from the window: its first block, straight from the cache.
sys_spawnf:
        call  fs_enter
        lw    a0, PCB_A1(s0)
        call  namei
        call  iget
        lw    t0, I_TYPE(a0)
        li    t1, T_FILE
        bne   t0, t1, 9f
        lw    t0, I_SIZE(a0)
        li    t1, 3
        blt   t0, t1, 9f               # no room for the magic word
        lw    a0, I_DIRECT(a0)
        beqz  a0, 9f
        call  bget
        lw    t0, BLOCK_W0(a0)
        li    t1, EXEC_MAGIC
        bne   t0, t1, 9f
        li    t0, DMAP                 # its page, from its kernel address
        sub   a0, a0, t0
        li    t0, PAGE
        div   s5, a0, t0
        call  current_pid
        mv    a2, a0                   # the caller is the parent
        li    s6, 1                    # from a program file
        call  spawn_page
        j     sys_return
9:      li    a0, E_NOEXEC
        j     sys_return

# --- helpers --------------------------------------------------------------------

# sua_on: let the kernel reach user memory; resume turns it off. Clobbers t0.
sua_on:
        li    t0, 0t+000
        csrw  ststatus, t0
        ret

# fs_enter: sua_on, and check the disk holds a filesystem; else end the
# call with E_NOFS. Clobbers a0, a1 and t0..t5.
fs_enter:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  sua_on
        li    t0, V_DISK
        lw    t0, DISK_BLOCKS(t0)
        li    t1, FS_INODE_BLOCK
        ble   t0, t1, 9f               # no room for block 0 and the inodes
        li    a0, 0
        call  bget
        lw    t0, FS_HEAD_MAGIC(a0)
        li    t1, FS_MAGIC
        bne   t0, t1, 9f
        lw    t0, FS_HEAD_VERSION(a0)
        li    t1, FS_VERSION
        bne   t0, t1, 9f
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret
9:      li    a0, E_NOFS
        j     sys_return

# fdget: a0 = the address of the caller's descriptor a1, if it is open;
# else end the call with E_BADF. Clobbers t0.
fdget:
        bltz  a1, 9f
        li    t0, NFD
        bge   a1, t0, 9f
        li    t0, FD
        mul   t0, a1, t0
        add   a0, s0, t0
        addi  a0, a0, PCB_FDS
        lw    t0, FD_INO(a0)
        beqz  t0, 9f
        ret
9:      li    a0, E_BADF
        j     sys_return

# utop: a0 = the last tryte the caller may name: its page's, or its
# block window's once it has one. Clobbers t0.
utop:
        li    a0, V_USER + 9841
        lw    t0, PCB_BLOCKPG(s0)
        beqz  t0, 1f
        li    a0, V_BLOCK + 9841
1:      ret

# urange: check the a1 trytes from a0 lie in the caller's page or block
# window; else end the call with E_FAULT. Clobbers a0, t0, t1.
urange:
        li    t0, V_USER - 9841
        blt   a0, t0, fs_fault
        add   t1, a0, a1
        addi  t1, t1, -1               # the last
        li    t0, V_USER + 9841
        lw    a0, PCB_BLOCKPG(s0)
        beqz  a0, 1f
        li    t0, V_BLOCK + 9841
1:      bgt   t1, t0, fs_fault
        ret

# iget: a0 = the kernel address of inode a0's first word, in the cache.
# Ends the call with E_IO for a number no inode has. Clobbers a0, a1
# and t0..t5.
iget:
        blez  a0, fs_eio
        li    t0, FS_INODES
        bge   a0, t0, fs_eio
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        li    a0, FS_INODE_BLOCK
        call  bget
        lw    t0, 3(sp)
        li    t1, INODE
        mul   t0, t0, t1
        add   a0, a0, t0
        addi  a0, a0, BLOCK_W0
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# bmap: a0 = the number of data block a1 (counting from 0) of the inode
# at a0, or NO_BLOCK for a hole. Clobbers a0, a1 and t0..t5.
bmap:
        li    t0, NDIRECT
        bge   a1, t0, 1f
        li    t0, 3
        mul   t0, a1, t0
        add   t0, a0, t0
        lw    a0, I_DIRECT(t0)
        ret
1:      sub   a1, a1, t0               # a1: its place in the indirect block
        lw    a0, I_INDIRECT(a0)
        beqz  a0, 2f                   # a hole, all of it
        li    t0, PAGE / 3
        bge   a1, t0, fs_eio           # past what a file can hold
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a1, 3(sp)
        call  bget
        lw    t0, 3(sp)
        li    t1, 3
        mul   t0, t0, t1
        add   a0, a0, t0
        lw    a0, BLOCK_W0(a0)
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret
2:      li    a0, NO_BLOCK
        ret

# namei: a0 = the inode the path at a0, in the caller's memory, names.
# Each name is looked up in the directory reached so far, starting at
# the root; slashes before, between and after names do not count. Ends
# the call with E_FAULT, E_NAMETOOLONG, E_NOTDIR, E_NOENT, or as bget
# does. Clobbers a0, a1, t0..t5 and s2..s6.
namei:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        mv    s2, a0                   # s2: where we are in the path
        li    t0, V_USER - 9841
        blt   s2, t0, fs_fault
        call  utop
        mv    s4, a0                   # s4: the last tryte it may reach
        li    s3, ROOT_INO             # s3: the inode reached
        li    s5, PATH_DEPTH           # s5: names it may still have
1:      bgt   s2, s4, fs_fault
        lt    t0, 0(s2)
        beqz  t0, 9f                   # the end
        li    t1, '/'
        bne   t0, t1, 2f
        addi  s2, s2, 1
        j     1b
2:      beqz  s5, fs_toolong
        addi  s5, s5, -1
        la    t2, kname                # copy the name, to end it with 0
        li    t3, NAME_MAX
3:      beqz  t3, fs_toolong
        st    t0, 0(t2)
        addi  t2, t2, 1
        addi  s2, s2, 1
        addi  t3, t3, -1
        bgt   s2, s4, fs_fault
        lt    t0, 0(s2)
        beqz  t0, 4f
        li    t1, '/'
        bne   t0, t1, 3b
4:      st    zero, 0(t2)
        mv    a0, s3                   # look it up in directory s3
        call  iget
        lw    t0, I_TYPE(a0)
        li    t1, T_DIR
        bne   t0, t1, fs_notdir
        lw    s6, I_SIZE(a0)
        li    t1, DIRENT
        div   s6, s6, t1               # s6: its entries, in one block
        li    t1, DIRENTS
        bgt   s6, t1, fs_eio           # more than one block holds
        beqz  s6, fs_noent
        lw    a0, I_DIRECT(a0)
        beqz  a0, fs_eio               # entries but no block
        call  bget
        addi  t2, a0, BLOCK_W0         # t2: the entry tried
5:      beqz  s6, fs_noent
        lw    t0, D_INO(t2)
        beqz  t0, 7f                   # unused
        addi  t3, t2, D_NAME
        la    t4, kname
6:      lt    t0, 0(t3)
        lt    t1, 0(t4)
        bne   t0, t1, 7f
        beqz  t0, 8f                   # the same, to the end
        addi  t3, t3, 1
        addi  t4, t4, 1
        j     6b
7:      addi  t2, t2, DIRENT
        addi  s6, s6, -1
        j     5b
8:      lw    s3, D_INO(t2)
        j     1b
9:      mv    a0, s3
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# How a call ends when it cannot go on.
fs_none:
        li    a0, 0
        j     sys_return
fs_inval:
        li    a0, E_INVAL
        j     sys_return
fs_fault:
        li    a0, E_FAULT
        j     sys_return
fs_toolong:
        li    a0, E_NAMETOOLONG
        j     sys_return
fs_notdir:
        li    a0, E_NOTDIR
        j     sys_return
fs_noent:
        li    a0, E_NOENT
        j     sys_return
fs_isdir:
        li    a0, E_ISDIR
        j     sys_return
fs_eio:
        li    a0, E_IO
        j     sys_return
        .nocompress
