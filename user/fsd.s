# The file server (docs/filesystem.md): a process that owns the
# filesystem on the disk and answers other processes' calls to open,
# read, write, make and remove its files and directories. It registers
# as "fs", protocol FS_PROTOCOL, before it takes its first call; clients
# find it by that name (SYS_LOOKUP).
#
# A file call is a SYS_CALL to the server with the FS_ operation in a2 and
# its arguments in a3..a5 (include/layout.s); the reply's first word is
# the result. The server takes one call at a time: it copies a path in
# with copyin, and data or a name out with copyout, while it holds the
# call. Each process's descriptors and current directory are kept here,
# and dropped when the kernel says the process has ended.
#
# Blocks come through the server's block windows, NWIN of them, which
# the disk server ("disk", DISK_PROTOCOL) reads blocks into and writes
# them from, a call each. The windows are used as a cache: the least
# recently used goes when another block is needed. The server assumes nothing else writes the disk while it runs. A call
# needs at most six blocks at once (block 0, the inode table, a
# directory, an indirect block, a data block or a new directory's), so
# none it holds is evicted under it.
#
# A call that changes the filesystem first gathers every block it will
# change, allocating new ones, and finds out whether it can be done
# (E_NOSPC, E_FAULT and the rest) before it changes anything; then it
# changes the blocks in its windows, marks them dirty, and before the
# reply goes every dirty block is written back (fs_flush). So a call
# that fails leaves the disk as it was, and one that is answered is on
# the disk: there is nothing to flush at power-off.
#
# Not a program on its own: a build includes it in a program's section.
# Its labels all start with fs_, since it shares the build's symbols.

        .compress
        .gp   USER_GP

# Find the disk server, waiting for it to start; one with another
# protocol counts as no disk. Then say it is ready by registering. A
# second file server finds the name taken, and leaves with why.
fs_main:
        li    a0, SYS_LOOKUP
        la    a1, fs_diskname
        li    a2, LOOKUP_WAIT
        sys
        bltz  a0, 1f
        li    t0, DISK_PROTOCOL
        bne   a1, t0, 1f
        sw    a0, fs_disk
1:      li    a0, SYS_REGISTER
        la    a1, fs_srvname
        li    a2, FS_PROTOCOL
        sys
        bgez  a0, fs_start
        mv    a1, a0
        li    a0, SYS_EXIT
        sys

fs_start:
        li    sp, USER_SP              # a fresh stack for every call: a
        li    a0, SYS_RECEIVE          # call that fails just replies
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, fs_notice
        mv    s0, a0                   # s0: the caller
        sw    a0, fs_caller
        sw    a2, fs_a1
        sw    a3, fs_a2
        sw    a4, fs_a3
        sw    zero, fs_entering
        bltz  a1, fs_inval
        li    t0, FS_NOPS
        bge   a1, t0, fs_inval
        li    t0, 3
        mul   t0, a1, t0
        la    t1, fs_ops
        add   t0, t0, t1
        lw    t0, 0(t0)
        jalr  zero, 0(t0)

fs_reply:                              # a0: the result
        sw    a0, fs_result
        call  fs_flush                 # what the call changed, to the disk
        lw    a2, fs_result
        mv    a1, s0
        li    a0, SYS_REPLY
        sys
        j     fs_start

# A process ended: close what it had open, and forget its directory.
fs_notice:
        li    t0, NOTE_ENDED
        bne   a1, t0, fs_start
        li    t0, NFD * FD
        mul   t0, a2, t0
        la    t1, fs_fds
        add   t1, t1, t0
        li    t2, NFD
1:      sw    zero, FD_INO(t1)
        addi  t1, t1, FD
        addi  t2, t2, -1
        bnez  t2, 1b
        mv    s0, a2                   # and its current directory
        call  fs_cwdaddr
        sw    zero, 0(a0)
        j     fs_start

# open(path, flags): the lowest free descriptor, at the start of the
# file or directory path names, for reading, writing or both (flags mod
# 3). O_CREAT makes an empty file if the name is free, O_TRUNC empties a
# file opened for writing, and O_APPEND writes at the end each time. A
# directory opens for reading only.
fs_open:
        call  fs_enter
        call  fs_fdfree                # one must be free, before anything changes
        lw    a0, fs_a2
        call  fs_oflags                # a0: the access mode
        bltz  a0, fs_inval
        sw    a0, fs_mode
        lw    a0, fs_a2
        li    t1, O_CREAT
        div   a0, a0, t1
        rem   a0, a0, t1
        bnez  a0, 1f
        lw    a0, fs_a1
        call  fs_namei
        j     3f
1:      lw    a0, fs_a1
        call  fs_namei_parent
        beqz  a1, 3f                   # the root, which is there
        call  fs_creat                 # a0: the inode, found or made
        bltz  a1, 4f                   # made: empty, nothing to truncate
3:      mv    s7, a0                   # s7: the inode
        call  fs_iget
        lw    t2, fs_mode
        lw    t0, I_TYPE(a0)
        li    t1, T_DIR
        bne   t0, t1, 2f
        bnez  t2, fs_isdir             # a directory, for writing
        j     5f
2:      beqz  t2, 5f                   # O_TRUNC only counts for writing
        lw    t0, fs_a2
        li    t1, O_TRUNC
        div   t0, t0, t1
        li    t1, 3
        rem   t0, t0, t1
        beqz  t0, 5f
        mv    a0, s7
        call  fs_itrunc
5:      mv    a0, s7
4:      mv    s7, a0
        call  fs_fdfree                # a1: the descriptor's record, a0 its number
        sw    s7, FD_INO(a1)
        sw    zero, FD_POS(a1)
        lw    t0, fs_a2
        sw    t0, FD_FLAGS(a1)
        j     fs_reply

# fs_fdfree: a0 = the caller's lowest free descriptor, a1 = its record;
# replies E_MFILE when all are in use. Clobbers t0.
fs_fdfree:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    a1, 0
        call  fs_fdaddr
        mv    a1, a0
        lw    ra, 0(sp)
        addi  sp, sp, 3
        li    a0, 0
1:      lw    t0, FD_INO(a1)
        beqz  t0, 2f
        addi  a1, a1, FD
        addi  a0, a0, 1
        li    t0, NFD
        blt   a0, t0, 1b
        li    a0, E_MFILE
        j     fs_reply
2:      ret

# fs_oflags: a0 = the access mode of open flags a0 (O_RDONLY, O_WRONLY or
# O_RDWR), or E_INVAL if they are not a mode plus some of O_CREAT,
# O_TRUNC and O_APPEND, each once. Clobbers a1, t0..t2.
fs_oflags:
        bltz  a0, 9f
        li    t0, 3 * O_APPEND
        bge   a0, t0, 9f
        li    t1, 3
        div   t0, a0, t1               # each flag above the mode is 0 or 1
        li    t2, 3
1:      beqz  t2, 2f
        rem   a1, t0, t1
        addi  a1, a1, -2
        beqz  a1, 9f
        div   t0, t0, t1
        addi  t2, t2, -1
        j     1b
2:      rem   a0, a0, t1
        ret
9:      li    a0, E_INVAL
        ret

# close(fd)
fs_close:
        lw    a1, fs_a1
        call  fs_fdget
        sw    zero, FD_INO(a0)
        li    a0, 0
        j     fs_reply

# read(fd, buffer, n): copy up to n trytes from the file to the buffer,
# no further than the end of the file or of the block the position is
# in, and move the position past them. A hole reads as zeros.
fs_read:
        call  fs_enter
        lw    a1, fs_a1
        call  fs_fdget
        mv    s2, a0                   # s2: the descriptor
        lw    t0, FD_FLAGS(s2)
        li    t1, 3
        rem   t0, t0, t1
        li    t1, O_WRONLY
        beq   t0, t1, fs_badf          # opened for writing only
        lw    s3, fs_a3                # s3: how many to copy
        bltz  s3, fs_inval
        lw    a0, FD_INO(s2)
        call  fs_iget
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
        call  fs_bmap
        beqz  a0, 4f                   # NO_BLOCK: a hole
        call  fs_bget
        add   a2, a0, s5
        addi  a2, a2, BLOCK_T0         # the first tryte to copy
        lw    a3, fs_a2
        mv    a4, s3
        mv    a1, s0
        li    a0, SYS_COPYOUT
        sys
        bnez  a0, fs_reply
        j     5f
4:      lw    s6, fs_a2                # s6: where the zeros go
        mv    s7, s3                   # s7: how many are left
3:      li    a4, FS_ZEROS
        ble   a4, s7, 6f
        mv    a4, s7
6:      sub   s7, s7, a4
        mv    a3, s6
        add   s6, s6, a4
        la    a2, fs_zeros
        mv    a1, s0
        li    a0, SYS_COPYOUT
        sys
        bnez  a0, fs_reply
        bnez  s7, 3b
5:      lw    t0, FD_POS(s2)
        add   t0, t0, s3
        sw    t0, FD_POS(s2)
        mv    a0, s3
        j     fs_reply

# lseek(fd, offset, whence): the position, set from the start, where it
# is or the end. It may pass the end of the file, but not its start.
fs_lseek:
        lw    a1, fs_a1
        call  fs_fdget
        mv    s2, a0                   # s2: the descriptor
        lw    t2, fs_a3
        li    t1, 0                    # SEEK_SET: from 0
        li    t0, SEEK_SET
        beq   t2, t0, 2f
        lw    t1, FD_POS(s2)
        li    t0, SEEK_CUR
        beq   t2, t0, 2f
        li    t0, SEEK_END
        bne   t2, t0, fs_inval
        call  fs_enter
        lw    a0, FD_INO(s2)
        call  fs_iget
        lw    t1, I_SIZE(a0)
2:      lw    t0, fs_a2
        add   a0, t0, t1
        bltz  a0, fs_inval
        sw    a0, FD_POS(s2)
        j     fs_reply

# readdir(fd, buffer): the next entry in use of a directory: its name to
# the buffer, NAME_MAX + 1 trytes, and its inode as the result; or 0 at
# the end. The position counts DIRENT trytes per entry, used or not.
fs_readdir:
        call  fs_enter
        lw    a1, fs_a1
        call  fs_fdget
        mv    s2, a0                   # s2: the descriptor
        lw    a0, FD_INO(s2)
        call  fs_iget
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
        call  fs_bget
        addi  s5, a0, BLOCK_W0         # s5: its first entry
1:      bge   s4, s3, fs_none
        li    t0, DIRENT
        mul   t1, s4, t0
        add   t1, t1, s5               # t1: entry s4
        addi  s4, s4, 1
        lw    s6, D_INO(t1)            # s6: the inode it names
        beqz  s6, 1b                   # unused
        addi  t1, t1, D_NAME
        la    t3, fs_name
        li    t4, NAME_MAX
2:      lt    t0, 0(t1)
        st    t0, 0(t3)
        addi  t1, t1, 1
        addi  t3, t3, 1
        addi  t4, t4, -1
        bnez  t4, 2b
        st    zero, 0(t3)              # ended, whatever the disk says
        li    a0, SYS_COPYOUT
        mv    a1, s0
        la    a2, fs_name
        lw    a3, fs_a2
        li    a4, NAME_MAX + 1
        sys
        bnez  a0, fs_reply
        li    t0, DIRENT
        mul   t0, s4, t0
        sw    t0, FD_POS(s2)
        mv    a0, s6
        j     fs_reply

# stat(path, buffer): what path names, as the ST_ words at the buffer.
fs_stat:
        call  fs_enter
        lw    a0, fs_a2
        li    t0, 3
        rem   t0, a0, t0
        bnez  t0, fs_fault             # words must be aligned
        lw    a0, fs_a1
        call  fs_namei
        mv    s2, a0                   # s2: the inode's number
        call  fs_iget
        la    t1, fs_statbuf
        sw    s2, ST_INO(t1)
        lw    t0, I_TYPE(a0)
        sw    t0, ST_TYPE(t1)
        lw    t0, I_LINKS(a0)
        sw    t0, ST_LINKS(t1)
        lw    t0, I_SIZE(a0)
        sw    t0, ST_SIZE(t1)
        li    a0, SYS_COPYOUT
        mv    a1, s0
        addi  a2, t1, ST_INO - 1
        lw    a3, fs_a2
        addi  a3, a3, ST_INO - 1
        li    a4, STAT
        sys
        j     fs_reply                 # 0, or E_FAULT

# spawnf(path): start the program file path names, as the caller's
# child, from its first block in one of the server's windows. The child
# starts in the caller's current directory. (Should the slot it takes be
# freed while this call runs, by another hart, the notice of that ends
# comes after and sends the child to the root: harmless, and rare, since
# the kernel hands slots out round the table.)
fs_spawn:
        call  fs_enter
        lw    a0, fs_a1
        call  fs_namei
        call  fs_iget
        lw    t0, I_TYPE(a0)
        li    t1, T_FILE
        bne   t0, t1, 9f
        lw    t0, I_SIZE(a0)
        li    t1, 3
        blt   t0, t1, 9f               # no room for the magic word
        lw    a0, I_DIRECT(a0)
        beqz  a0, 9f
        call  fs_bget
        lw    t0, BLOCK_W0(a0)
        li    t1, EXEC_MAGIC
        bne   t0, t1, 9f
        li    t0, V_BLOCK              # its window
        sub   a1, a0, t0
        li    t0, PAGE
        div   a1, a1, t0
        mv    a2, s0                   # the caller is the parent
        li    a0, SYS_SPAWNW
        sys
        bltz  a0, fs_reply
        mv    s2, a0                   # s2: the child, which starts in the
        call  fs_cwdaddr               # caller's directory
        lw    s3, 0(a0)
        mv    s0, s2
        call  fs_cwdaddr
        sw    s3, 0(a0)
        lw    a1, fs_caller
        mv    s0, a1
        mv    a0, s2
        j     fs_reply
9:      li    a0, E_NOEXEC
        j     fs_reply

# write(fd, buffer, n): copy up to n trytes from the buffer to the file
# at the position (its end, with O_APPEND), no further than the end of
# the block the position is in, and move the position past them: how
# many. A block not there yet is allocated, and the indirect block too.
fs_write:
        call  fs_enter
        lw    a1, fs_a1
        call  fs_fdget
        mv    s2, a0                   # s2: the descriptor
        lw    t0, FD_FLAGS(s2)
        li    t1, 3
        rem   t0, t0, t1
        beqz  t0, fs_badf              # opened for reading only
        lw    s3, fs_a3                # s3: how many to copy
        bltz  s3, fs_inval
        lw    s4, FD_INO(s2)           # s4: the inode
        mv    a0, s4
        call  fs_iget
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
        sw    t1, fs_off
        sub   t1, t2, t1               # what is left of the block
        bge   t1, s3, 2f
        mv    s3, t1
2:      li    t0, NDIRECT + PAGE / 3
        bge   s6, t0, 9f               # past what a file can hold
        sw    zero, fs_newind
        sw    zero, fs_newdata
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
        sw    t0, fs_newind
        li    a0, 0
        call  fs_balloc
        mv    s8, a0
        call  fs_bnew
        j     5f
4:      mv    a0, s8
        call  fs_bget
        addi  t0, s6, -NDIRECT
        li    t1, 3
        mul   t0, t0, t1
        add   t0, a0, t0
        lw    s7, BLOCK_W0(t0)
5:      bnez  s7, 6f
        li    t0, 1                    # no data block yet
        sw    t0, fs_newdata
        li    a0, 0
        lw    t0, fs_newind
        beqz  t0, 0f
        addi  a0, s8, 1                # past a new indirect block
0:      call  fs_balloc
        mv    s7, a0
        call  fs_bnew
        j     7f
6:      mv    a0, s7
        call  fs_bget

        # Every block is here. The trytes first: a buffer that is not all
        # the caller's fails the call before anything changes.
7:      mv    a0, s7
        call  fs_bget
        lw    t0, fs_off
        add   a3, a0, t0
        addi  a3, a3, BLOCK_T0         # where the trytes go
        lw    a2, fs_a2
        mv    a4, s3
        mv    a1, s0
        li    a0, SYS_COPYIN
        sys
        bnez  a0, fs_reply
        mv    a0, s7
        call  fs_bdirty
        lw    t0, fs_newind
        lw    t1, fs_newdata
        add   t0, t0, t1
        beqz  t0, 8f                   # nothing allocated
        li    a0, 0
        call  fs_bget
        li    t1, MAP_USED
        add   t0, a0, s7
        st    t1, FS_MAP(t0)
        lw    t0, fs_newind
        beqz  t0, 0f
        add   t0, a0, s8
        st    t1, FS_MAP(t0)
0:      li    a0, 0
        call  fs_bdirty
8:      mv    a0, s4
        call  fs_iget
        li    t0, NDIRECT
        bge   s6, t0, 1f
        li    t0, 3
        mul   t0, s6, t0
        add   t0, a0, t0
        sw    s7, I_DIRECT(t0)
        j     2f
1:      sw    s8, I_INDIRECT(a0)
        mv    a0, s8
        call  fs_bget
        addi  t0, s6, -NDIRECT
        li    t1, 3
        mul   t0, t0, t1
        add   t0, a0, t0
        sw    s7, BLOCK_W0(t0)
        mv    a0, s8
        call  fs_bdirty
2:      mv    a0, s4
        call  fs_iget
        add   s5, s5, s3
        lw    t0, I_SIZE(a0)
        bge   t0, s5, 4f
        sw    s5, I_SIZE(a0)           # it grew
4:      sw    s5, FD_POS(s2)
        li    a0, FS_INODE_BLOCK
        call  fs_bdirty
        mv    a0, s3
        j     fs_reply
9:      li    a0, E_FBIG
        j     fs_reply

# unlink(path): remove a file's name, and the file once it has no other.
# A directory is E_ISDIR (rmdir removes those), and a file some process
# has open is E_BUSY, since a descriptor names the inode.
fs_unlink:
        call  fs_enter
        lw    a0, fs_a1
        call  fs_namei_parent
        beqz  a1, fs_isdir             # the root
        mv    s8, a0                   # s8: the directory
        call  fs_dotcheck
        mv    a0, s8
        call  fs_dirfind
        beqz  a0, fs_noent
        mv    s3, a0                   # s3: the entry
        lw    s4, D_INO(s3)            # s4: the file
        mv    a0, s4
        call  fs_iget
        lw    t0, I_TYPE(a0)
        li    t1, T_DIR
        beq   t0, t1, fs_isdir
        mv    a0, s4
        call  fs_inoopen
        mv    a0, s4
        call  fs_truncprep             # in case this is its last name

        mv    a0, s3                   # change: the entry goes
        li    a1, NO_INO
        la    a2, fs_noname
        call  fs_direntset
        mv    a0, s8
        call  fs_dirdirty
        mv    a0, s4
        call  fs_iget
        lw    t0, I_LINKS(a0)
        addi  t0, t0, -1
        sw    t0, I_LINKS(a0)
        bgtz  t0, 1f
        mv    a0, s4                   # no name left: neither is the file
        call  fs_ifree
1:      li    a0, FS_INODE_BLOCK
        call  fs_bdirty
        li    a0, 0
        j     fs_reply

# mkdir(path): a new, empty directory, holding . and ..
fs_mkdir:
        call  fs_enter
        lw    a0, fs_a1
        call  fs_namei_parent
        beqz  a1, fs_exist             # the root
        mv    s8, a0                   # s8: the parent
        call  fs_nameok
        mv    a0, s8
        call  fs_dirfind
        bnez  a0, fs_exist
        beqz  a1, fs_nospc             # the parent is full
        mv    s2, a1                   # s2: the entry to use
        mv    s3, a2                   # s3: 1 if that grows the parent
        call  fs_ialloc
        mv    s4, a0                   # s4: the new directory's inode
        li    a0, 0
        call  fs_balloc
        mv    s5, a0                   # s5: its block
        call  fs_bnew

        li    a0, 0                    # change
        call  fs_bget
        add   t0, a0, s5
        li    t1, MAP_USED
        st    t1, FS_MAP(t0)
        li    a0, 0
        call  fs_bdirty
        mv    a0, s4
        call  fs_iget
        call  fs_inodeclear
        li    t0, T_DIR
        sw    t0, I_TYPE(a0)
        li    t0, 2                    # its name and its .
        sw    t0, I_LINKS(a0)
        li    t0, 2 * DIRENT
        sw    t0, I_SIZE(a0)
        sw    s5, I_DIRECT(a0)
        mv    a0, s5
        call  fs_bget
        addi  a0, a0, BLOCK_W0
        mv    a1, s4
        la    a2, fs_dot
        call  fs_direntset
        mv    a0, s5
        call  fs_bget
        addi  a0, a0, BLOCK_W0 + DIRENT
        mv    a1, s8
        la    a2, fs_dotdot
        call  fs_direntset
        mv    a0, s5
        call  fs_bdirty
        mv    a0, s2
        mv    a1, s4
        la    a2, fs_name
        call  fs_direntset
        mv    a0, s8
        call  fs_iget
        lw    t0, I_LINKS(a0)          # the new directory's ..
        addi  t0, t0, 1
        sw    t0, I_LINKS(a0)
        beqz  s3, 1f
        lw    t0, I_SIZE(a0)
        addi  t0, t0, DIRENT
        sw    t0, I_SIZE(a0)
1:      mv    a0, s8
        call  fs_dirdirty
        li    a0, FS_INODE_BLOCK
        call  fs_bdirty
        li    a0, 0
        j     fs_reply

# rmdir(path): remove a directory holding nothing but . and .. . One a
# process has open is E_BUSY, as is the root.
fs_rmdir:
        call  fs_enter
        lw    a0, fs_a1
        call  fs_namei_parent
        beqz  a1, fs_busy              # the root
        mv    s8, a0                   # s8: the parent
        call  fs_dotcheck
        mv    a0, s8
        call  fs_dirfind
        beqz  a0, fs_noent
        mv    s3, a0                   # s3: the entry
        lw    s4, D_INO(s3)            # s4: the directory to go
        mv    a0, s4
        call  fs_iget
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
        call  fs_bget
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
        call  fs_inoopen
        mv    a0, s4
        call  fs_truncprep

        mv    a0, s3                   # change: the entry goes
        li    a1, NO_INO
        la    a2, fs_noname
        call  fs_direntset
        mv    a0, s8
        call  fs_dirdirty
        mv    a0, s4
        call  fs_ifree
        mv    a0, s8
        call  fs_iget
        lw    t0, I_LINKS(a0)          # its .. named the parent
        addi  t0, t0, -1
        sw    t0, I_LINKS(a0)
        li    a0, FS_INODE_BLOCK
        call  fs_bdirty
        li    a0, 0
        j     fs_reply

# chdir(path): make the directory path names the caller's current one.
fs_chdir:
        call  fs_enter
        lw    a0, fs_a1
        call  fs_namei
        mv    s2, a0                   # s2: its inode
        call  fs_iget
        lw    t0, I_TYPE(a0)
        li    t1, T_DIR
        bne   t0, t1, fs_notdir
        call  fs_cwdaddr
        sw    s2, 0(a0)
        j     fs_none

# getcwd(buffer, n): the path from the root to the caller's current
# directory, ended with 0, to the buffer if n trytes hold it: its length.
# It is put together from the end of fs_path back, a name at a time:
# each directory's .. is its parent, and the parent's entry for it its
# name.
fs_getcwd:
        call  fs_enter
        call  fs_cwdaddr
        lw    s2, 0(a0)                # s2: the directory reached
        bnez  s2, 0f
        li    s2, ROOT_INO
0:      la    s3, fs_path + PATH_MAX   # s3: where the path starts so far
        st    zero, 0(s3)
1:      li    t0, ROOT_INO
        beq   s2, t0, 5f
        la    t0, fs_name              # its parent: its entry ..
        li    t1, '.'
        st    t1, 0(t0)
        st    t1, 1(t0)
        st    zero, 2(t0)
        mv    a0, s2
        call  fs_dirfind
        beqz  a0, fs_eio
        lw    s4, D_INO(a0)            # s4: the parent
        mv    a0, s4
        mv    a1, s2
        call  fs_dirino
        beqz  a0, fs_eio               # the parent has no name for it
        addi  t1, a0, D_NAME
        li    t2, 0                    # t2: the name's length
2:      add   t0, t1, t2
        lt    t0, 0(t0)
        beqz  t0, 3f
        addi  t2, t2, 1
        j     2b
3:      sub   s3, s3, t2
        addi  s3, s3, -1               # room for a slash and the name
        la    t0, fs_path
        blt   s3, t0, fs_toolong
        li    t0, '/'
        st    t0, 0(s3)
        addi  t3, s3, 1
4:      beqz  t2, 6f
        lt    t0, 0(t1)
        st    t0, 0(t3)
        addi  t1, t1, 1
        addi  t3, t3, 1
        addi  t2, t2, -1
        j     4b
6:      mv    s2, s4
        j     1b
5:      la    t0, fs_path + PATH_MAX   # the root alone is /
        bne   s3, t0, 7f
        addi  s3, s3, -1
        li    t1, '/'
        st    t1, 0(s3)
7:      la    t0, fs_path + PATH_MAX
        sub   s5, t0, s3               # s5: its length
        addi  a4, s5, 1
        lw    t0, fs_a2
        bgt   a4, t0, 8f
        li    a0, SYS_COPYOUT
        mv    a1, s0
        mv    a2, s3
        lw    a3, fs_a1
        sys
        bnez  a0, fs_fault
        mv    a0, s5
        j     fs_reply
8:      li    a0, E_NOROOM
        j     fs_reply

# --- helpers for changing the filesystem -----------------------------------------

# fs_creat: for open with O_CREAT: a0 = the inode named fs_name in
# directory a0 and a1 = 0, if there is one; else a new, empty file of
# that name, and a1 = -1. Clobbers a2..a4, t0..t6 and s2..s6.
fs_creat:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)                # the directory
        call  fs_dirfind
        beqz  a0, 1f
        lw    a0, D_INO(a0)
        li    a1, 0
        j     9f
1:      beqz  a1, fs_nospc             # the directory is full
        mv    s2, a1                   # s2: the entry to use
        mv    s3, a2                   # s3: 1 if that grows the directory
        call  fs_nameok
        call  fs_ialloc
        mv    s4, a0                   # s4: the new file

        mv    a0, s4                   # change
        call  fs_iget
        call  fs_inodeclear
        li    t0, T_FILE
        sw    t0, I_TYPE(a0)
        li    t0, 1
        sw    t0, I_LINKS(a0)
        mv    a0, s2
        mv    a1, s4
        la    a2, fs_name
        call  fs_direntset
        beqz  s3, 2f
        lw    a0, 3(sp)
        call  fs_iget
        lw    t0, I_SIZE(a0)
        addi  t0, t0, DIRENT
        sw    t0, I_SIZE(a0)
2:      lw    a0, 3(sp)
        call  fs_dirdirty
        li    a0, FS_INODE_BLOCK
        call  fs_bdirty
        mv    a0, s4
        li    a1, -1
9:      lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# fs_dirfind: look fs_name up in directory a0. a0 = the address of its
# entry in a window, or 0; a1 = an entry a new name could take, or 0 when
# the directory is full, and a2 = 1 if that entry is past the
# directory's end. Replies E_NOTDIR if a0 is not a directory. Clobbers
# a3, t0..t6 and s6.
fs_dirfind:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  fs_iget
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
        call  fs_bget
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
        la    t4, fs_name
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

# fs_cwdaddr: a0 = where the current directory of process s0 is kept.
# Clobbers t0.
fs_cwdaddr:
        li    t0, 3
        mul   t0, s0, t0
        la    a0, fs_cwd
        add   a0, a0, t0
        ret

# fs_dirino: a0 = the address of the entry of directory a0 that names
# inode a1, in a window, or 0. Replies E_NOTDIR if a0 is not a
# directory. Clobbers a1..a3, t0..t6 and s6.
fs_dirino:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a1, 3(sp)
        call  fs_iget
        lw    t0, I_TYPE(a0)
        li    t1, T_DIR
        bne   t0, t1, fs_notdir
        lw    s6, I_SIZE(a0)
        li    t1, DIRENT
        div   s6, s6, t1               # s6: its entries
        li    t1, DIRENTS
        bgt   s6, t1, fs_eio
        lw    a0, I_DIRECT(a0)
        beqz  a0, fs_eio
        call  fs_bget
        addi  t2, a0, BLOCK_W0         # t2: the entry looked at
        lw    t3, 3(sp)
1:      beqz  s6, 8f
        lw    t0, D_INO(t2)
        beq   t0, t3, 9f
        addi  t2, t2, DIRENT
        addi  s6, s6, -1
        j     1b
8:      li    t2, 0
9:      mv    a0, t2
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# fs_dotcheck: reply E_INVAL if fs_name is . or .., which every
# directory has and none may lose or gain. Clobbers t0, t1.
fs_dotcheck:
        la    t1, fs_name
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

# fs_nameok: reply E_INVAL unless fs_name may be a new name: not . or ..,
# and no space or control character (fs_namei keeps out /). Clobbers
# t0..t2.
fs_nameok:
        mv    t2, ra
        call  fs_dotcheck
        mv    ra, t2
        la    t1, fs_name
1:      lt    t0, 0(t1)
        beqz  t0, 9f
        li    t2, ' '
        ble   t0, t2, fs_inval
        addi  t1, t1, 1
        j     1b
9:      ret

# fs_ialloc: a0 = the lowest free inode; replies E_NOSPC when there is
# none. Clobbers a1..a3, t0..t6.
fs_ialloc:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    a0, FS_INODE_BLOCK
        call  fs_bget
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

# fs_balloc: a0 = the lowest free block from a0 on; replies E_NOSPC when
# there is none. The map is not changed: the caller marks it, and asks
# for a second block from past the first. Clobbers a1..a3, t0..t6.
fs_balloc:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        li    a0, 0
        call  fs_bget
        lw    t2, 3(sp)                # t2: the block looked at
        li    t0, FS_INODE_BLOCK + 1
        bge   t2, t0, 1f
        mv    t2, t0
1:      lw    t3, FS_HEAD_BLOCKS(a0)   # t3: where the filesystem ends
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

# fs_truncprep: read what fs_itrunc and fs_ifree will need for inode a0,
# its indirect block, so that nothing they do can fail. Clobbers a0..a3,
# t0..t6.
fs_truncprep:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  fs_iget
        lw    a0, I_INDIRECT(a0)
        beqz  a0, 1f
        call  fs_bget
1:      lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# fs_itrunc: empty inode a0: free each block it holds in the map, and
# clear its size and block numbers. Marks block 0 and the inode table
# dirty. Clobbers a0..a3, t0..t6.
fs_itrunc:
        addi  sp, sp, -9
        sw    ra, 0(sp)
        sw    a0, 3(sp)                # 3: the inode, 6: block 0
        call  fs_truncprep
        li    a0, 0
        call  fs_bget
        sw    a0, 6(sp)
        lw    a0, 3(sp)
        call  fs_iget
        mv    a2, a0                   # a2: the inode
        lw    a1, 6(sp)
        addi  t1, a2, I_DIRECT
        li    t2, NDIRECT
1:      lw    t0, 0(t1)                # each direct block
        call  fs_mapfree
        sw    zero, 0(t1)
        addi  t1, t1, 3
        addi  t2, t2, -1
        bnez  t2, 1b
        sw    zero, I_SIZE(a2)
        lw    a0, I_INDIRECT(a2)
        beqz  a0, 3f
        sw    zero, I_INDIRECT(a2)
        mv    t0, a0
        call  fs_mapfree
        call  fs_bget                  # its numbers, still as they were
        lw    a1, 6(sp)
        addi  t1, a0, BLOCK_W0
        li    t2, PAGE / 3
2:      lw    t0, 0(t1)
        call  fs_mapfree
        addi  t1, t1, 3
        addi  t2, t2, -1
        bnez  t2, 2b
3:      li    a0, 0
        call  fs_bdirty
        li    a0, FS_INODE_BLOCK
        call  fs_bdirty
        lw    ra, 0(sp)
        addi  sp, sp, 9
        ret

# fs_mapfree: mark block t0 free in the map of block 0 at a1. NO_BLOCK,
# and a number past the map, which only a damaged filesystem holds, are
# left alone. Clobbers t0, t3.
fs_mapfree:
        blez  t0, 9f
        li    t3, FS_MAX_BLOCKS
        bge   t0, t3, 9f
        add   t0, a1, t0
        st    zero, FS_MAP(t0)         # MAP_FREE
9:      ret

# fs_ifree: fs_itrunc inode a0, then mark it unused. Clobbers as fs_itrunc.
fs_ifree:
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        call  fs_itrunc
        lw    a0, 3(sp)
        call  fs_iget
        call  fs_inodeclear
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# fs_inodeclear: zero the inode at a0: T_FREE, no links, no blocks.
# Clobbers t0, t1.
fs_inodeclear:
        mv    t0, a0
        addi  t1, a0, INODE - 3
1:      sw    zero, 0(t0)
        addi  t0, t0, 3
        ble   t0, t1, 1b
        ret

# fs_inoopen: reply E_BUSY if any process has inode a0 open, or has it as
# its current directory. The kernel
# tells the server of each process that ends, so every descriptor here
# is a live process's. Clobbers t0..t2.
fs_inoopen:
        la    t1, fs_fds
        li    t2, NPROC * NFD
1:      lw    t0, FD_INO(t1)
        beq   t0, a0, fs_busy
        addi  t1, t1, FD
        addi  t2, t2, -1
        bnez  t2, 1b
        la    t1, fs_cwd               # nor anyone's current directory
        li    t2, NPROC
2:      lw    t0, 0(t1)
        beq   t0, a0, fs_busy
        addi  t1, t1, 3
        addi  t2, t2, -1
        bnez  t2, 2b
        ret

# fs_direntset: make the directory entry at a0 name inode a1 with the
# string at a2, zero-padded. Clobbers a2, t0..t2.
fs_direntset:
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

# fs_dirdirty: mark directory a0's block dirty. Clobbers a0..a3, t0..t6.
fs_dirdirty:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  fs_iget
        lw    a0, I_DIRECT(a0)
        call  fs_bdirty
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# fs_bnew: a0 = the centre of a window holding block a0, all zeros: a
# block just allocated, whatever the disk held there. Clobbers as fs_bget.
fs_bnew:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  fs_bget
        addi  t0, a0, -9840
        addi  t1, a0, 9840
1:      sw    zero, 0(t0)
        addi  t0, t0, 3
        ble   t0, t1, 1b
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# fs_bdirty: mark the window holding block a0 changed, so fs_flush
# writes it. Clobbers t0..t2.
fs_bdirty:
        addi  t2, a0, 1
        la    t1, fs_wblk
        li    t0, NWIN
1:      lw    a0, 0(t1)
        beq   a0, t2, 2f
        addi  t1, t1, 3
        addi  t0, t0, -1
        bnez  t0, 1b
        ret                            # not here: cannot happen
2:      li    t0, 1
        sw    t0, NWIN * 6(t1)         # fs_wdirty
        ret

# fs_flush: write every changed window back to its block. A block the
# disk server refuses makes the reply E_IO. Clobbers a0..a4, t0..t3.
fs_flush:
        li    t3, 0                    # t3: the window
1:      li    t0, 3
        mul   t0, t3, t0
        la    t1, fs_wdirty
        add   t1, t1, t0
        lw    t2, 0(t1)
        beqz  t2, 2f
        sw    zero, 0(t1)
        la    t1, fs_wblk
        add   t1, t1, t0
        lw    a3, 0(t1)
        addi  a3, a3, -1
        li    t0, PAGE
        mul   a4, t3, t0
        li    t0, V_BLOCK
        add   a4, a4, t0
        li    a2, DK_WRITE
        lw    a1, fs_disk
        li    a0, SYS_CALL
        sys
        beqz  a0, 2f
        li    t0, E_IO
        sw    t0, fs_result
2:      addi  t3, t3, 1
        li    t0, NWIN
        blt   t3, t0, 1b
        ret


# --- helpers --------------------------------------------------------------------

# fs_enter: check the disk holds a filesystem; else reply E_NOFS.
# Clobbers a0..a3 and t0..t6.
fs_enter:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        li    t0, 1                    # a disk that refuses block 0 has
        sw    t0, fs_entering          # no filesystem, rather than failed
        li    a0, 0
        call  fs_bget
        sw    zero, fs_entering
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
        j     fs_reply

# fs_fdaddr: a0 = the record of the caller's descriptor a1. Clobbers t0.
fs_fdaddr:
        li    t0, NFD
        mul   t0, s0, t0
        add   t0, t0, a1
        li    a0, FD
        mul   t0, t0, a0
        la    a0, fs_fds
        add   a0, a0, t0
        ret

# fs_fdget: as fs_fdaddr, if descriptor a1 is open; else reply E_BADF.
# Clobbers t0.
fs_fdget:
        bltz  a1, 9f
        li    t0, NFD
        bge   a1, t0, 9f
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  fs_fdaddr
        lw    ra, 0(sp)
        addi  sp, sp, 3
        lw    t0, FD_INO(a0)
        beqz  t0, 9f
        ret
9:      li    a0, E_BADF
        j     fs_reply

# fs_bget: a0 = the centre of a window holding block a0, read into the
# least recently used window if no window has it. Replies E_IO when the
# disk server refuses it or is not there (E_NOFS in fs_enter), or
# E_NOMEM when the kernel has no page for a new window. Clobbers a0..a4
# and t0..t6.
fs_bget:
        lw    t3, fs_clock
        addi  t3, t3, 1
        sw    t3, fs_clock             # t3: now
        addi  t6, a0, 1                # t6: what a window holding it says
        la    t1, fs_wblk
        li    t0, 0                    # t0: the window looked at
        li    t4, 0                    # t4: the one to take, if none has it
        li    t5, 1000000000           # t5: when that was last used
1:      lw    t2, 0(t1)
        beq   t2, t6, 4f               # it is here
        lw    t2, NWIN * 6(t1)         # fs_wdirty: kept until written
        bnez  t2, 2f
        lw    t2, NWIN * 3(t1)         # fs_wuse
        bge   t2, t5, 2f
        mv    t4, t0
        mv    t5, t2
2:      addi  t1, t1, 3
        addi  t0, t0, 1
        li    t2, NWIN
        blt   t0, t2, 1b

        li    t0, 3                    # read it into window t4
        mul   t1, t4, t0
        la    t0, fs_wblk
        add   t1, t1, t0
        sw    zero, 0(t1)              # holds nothing, unless the read works
        mv    a1, t4
        mv    t4, t1
        mv    t5, a0
        li    a0, SYS_WINDOW           # made on first use
        sys
        bnez  a0, 8f
        li    t0, PAGE
        mul   a4, a1, t0
        li    t0, V_BLOCK
        add   a4, a4, t0
        mv    a3, t5
        li    a2, DK_READ
        lw    a1, fs_disk
        li    a0, SYS_CALL
        sys
        bnez  a0, 8f
        addi  t5, t5, 1
        sw    t5, 0(t4)
        mv    t1, t4
4:      sw    t3, NWIN * 3(t1)         # used now
        la    t0, fs_wblk
        sub   t1, t1, t0
        li    t0, PAGE / 3             # 3 trytes per entry, PAGE per window
        mul   t1, t1, t0
        li    a0, V_BLOCK
        add   a0, a0, t1
        ret
8:      lw    t0, fs_entering
        bnez  t0, 9f
        li    t0, E_NOMEM
        beq   a0, t0, fs_reply
        j     fs_eio
9:      li    a0, E_NOFS
        j     fs_reply

# fs_iget: a0 = the address of inode a0's first word, in the inode
# table's window. Replies E_IO for a number no inode has. Clobbers a0..a3
# and t0..t6.
fs_iget:
        blez  a0, fs_eio
        li    t0, FS_INODES
        bge   a0, t0, fs_eio
        addi  sp, sp, -6
        sw    ra, 0(sp)
        sw    a0, 3(sp)
        li    a0, FS_INODE_BLOCK
        call  fs_bget
        lw    t0, 3(sp)
        li    t1, INODE
        mul   t0, t0, t1
        add   a0, a0, t0
        addi  a0, a0, BLOCK_W0
        lw    ra, 0(sp)
        addi  sp, sp, 6
        ret

# fs_bmap: a0 = the number of data block a1 (counting from 0) of the
# inode at a0, or NO_BLOCK for a hole. Clobbers a0..a3 and t0..t6.
fs_bmap:
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
        call  fs_bget
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

# fs_getpath: copy the path at a0 in the caller's memory to fs_path, all
# at once if the caller's memory goes on that far, else a tryte at a
# time up to its end. Replies E_FAULT if the path runs out of the
# caller's memory, E_NAMETOOLONG if it is longer than PATH_MAX. Clobbers
# a0..a4, t0..t2 and s7, s8.
fs_getpath:
        mv    s7, a0                   # s7: where it is
        mv    a2, a0
        li    a0, SYS_COPYIN
        mv    a1, s0
        la    a3, fs_path
        li    a4, PATH_MAX + 1
        sys
        beqz  a0, 3f
        li    s8, 0                    # s8: trytes copied
1:      li    a0, SYS_COPYIN
        mv    a1, s0
        add   a2, s7, s8
        la    a3, fs_path
        add   a3, a3, s8
        li    a4, 1
        sys
        bnez  a0, fs_fault
        la    t0, fs_path
        add   t0, t0, s8
        lt    t0, 0(t0)
        beqz  t0, 4f
        addi  s8, s8, 1
        li    t0, PATH_MAX + 1
        blt   s8, t0, 1b
        j     fs_toolong
3:      la    t0, fs_path              # a 0 within PATH_MAX + 1 trytes
        li    t1, PATH_MAX + 1
2:      lt    t2, 0(t0)
        beqz  t2, 4f
        addi  t0, t0, 1
        addi  t1, t1, -1
        bnez  t1, 2b
        j     fs_toolong
4:      ret

# fs_namei: a0 = the inode the path at a0, in the caller's memory, names.
# Each name is looked up in the directory reached so far, starting at
# the root if the path starts with a slash, else at the caller's current
# directory; more slashes between and after names do not count, and an
# empty path is E_NOENT.
# Replies E_FAULT, E_NAMETOOLONG, E_NOTDIR, E_NOENT, or as fs_bget does.
# Clobbers a0..a4, t0..t6 and s2..s8.
fs_namei:
        sw    zero, fs_parent
        j     0f
# fs_namei_parent: as fs_namei, for a call that makes or removes what
# the path names: a0 = the directory its last name is in, with that name
# in fs_name, and a1 = 1; or a1 = 0 when the path names the root, which
# has no name. Clobbers as fs_namei.
fs_namei_parent:
        li    t0, 1
        sw    t0, fs_parent
0:      addi  sp, sp, -3
        sw    ra, 0(sp)
        call  fs_getpath
        la    s2, fs_path              # s2: where we are in the path
        li    s3, ROOT_INO             # s3: the inode reached
        lt    t0, 0(s2)
        beqz  t0, fs_noent             # an empty path names nothing
        li    t1, '/'
        beq   t0, t1, 1f
        call  fs_cwdaddr               # no slash first: from the caller's
        lw    t0, 0(a0)                # directory, 0 while it is the root
        beqz  t0, 1f
        mv    s3, t0
1:      lt    t0, 0(s2)
        beqz  t0, 9f                   # the end
        li    t1, '/'
        bne   t0, t1, 2f
        addi  s2, s2, 1
        j     1b
2:      la    t2, fs_name              # copy the name, to end it with 0
        li    t3, NAME_MAX
3:      beqz  t3, fs_toolong
        st    t0, 0(t2)
        addi  t2, t2, 1
        addi  s2, s2, 1
        addi  t3, t3, -1
        lt    t0, 0(s2)
        beqz  t0, 4f
        li    t1, '/'
        bne   t0, t1, 3b
4:      st    zero, 0(t2)
        lw    t0, fs_parent
        beqz  t0, 0f
        mv    t1, s2                   # the last name? Then s3 is its directory
5:      lt    t0, 0(t1)
        beqz  t0, 10f
        li    t2, '/'
        bne   t0, t2, 0f
        addi  t1, t1, 1
        j     5b
0:      mv    a0, s3                   # look it up in directory s3
        call  fs_iget
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
        call  fs_bget
        addi  t2, a0, BLOCK_W0         # t2: the entry tried
5:      beqz  s6, fs_noent
        lw    t0, D_INO(t2)
        beqz  t0, 7f                   # unused
        addi  t3, t2, D_NAME
        la    t4, fs_name
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
9:      li    a1, 0                    # no name at all: the root
        j     11f
10:     li    a1, 1
11:     mv    a0, s3
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# How a call ends when it cannot go on.
fs_none:
        li    a0, 0
        j     fs_reply
fs_inval:
        li    a0, E_INVAL
        j     fs_reply
fs_fault:
        li    a0, E_FAULT
        j     fs_reply
fs_toolong:
        li    a0, E_NAMETOOLONG
        j     fs_reply
fs_notdir:
        li    a0, E_NOTDIR
        j     fs_reply
fs_noent:
        li    a0, E_NOENT
        j     fs_reply
fs_isdir:
        li    a0, E_ISDIR
        j     fs_reply
fs_eio:
        li    a0, E_IO
        j     fs_reply
fs_badf:
        li    a0, E_BADF
        j     fs_reply
fs_exist:
        li    a0, E_EXIST
        j     fs_reply
fs_nospc:
        li    a0, E_NOSPC
        j     fs_reply
fs_notempty:
        li    a0, E_NOTEMPTY
        j     fs_reply
fs_busy:
        li    a0, E_BUSY
        j     fs_reply

        .equ  FS_NOPS, 13              # the operations, by FS_ number
fs_ops: .word fs_open, fs_close, fs_read, fs_lseek, fs_readdir, fs_stat, fs_spawn
        .word fs_write, fs_unlink, fs_mkdir, fs_rmdir, fs_chdir, fs_getcwd
        .assert FS_GETCWD == FS_NOPS - 1, "fs_ops must list every FS_ operation"

        .equ  FS_NODISK, -1            # fs_disk with no disk server: no process
                                       # has the number, so a call is E_NOPROC
fs_disk: .word FS_NODISK               # the disk server
fs_caller: .word 0                     # who made the call
fs_a1:  .word 0                        # the call's arguments
fs_a2:  .word 0
fs_a3:  .word 0
fs_entering: .word 0                   # 1 while fs_enter reads block 0
fs_clock: .word 0                      # counts fs_bget calls
fs_result: .word 0                     # what fs_reply answers
fs_mode: .word 0                       # open: the access mode
fs_off: .word 0                        # write: the position in its block,
fs_newind: .word 0                     # 1 if the indirect block is new,
fs_newdata: .word 0                    # 1 if the data block is new
fs_parent: .word 0                     # 1: fs_namei stops before the last name
fs_wblk: .words NWIN                   # the block each window holds, plus 1;
fs_wuse: .words NWIN                   # 0 for none. When each was last used,
fs_wdirty: .words NWIN                 # and 1 if it was changed since read
fs_statbuf: .words STAT / 3
fs_fds: .words NPROC * NFD * FD / 3    # each process's descriptors
fs_cwd: .words NPROC                   # each one's current directory, 0 the root
        .equ  FS_ZEROS, 243            # trytes of zeros a hole is read from
fs_zeros: .zero FS_ZEROS
fs_name: .zero NAME_MAX + 1
fs_srvname: .string "fs"             # what it registers as
fs_diskname: .string "disk"           # whom it reads and writes blocks with
fs_dot: .string "."
fs_dotdot: .string ".."
fs_noname: .string ""
fs_path: .zero PATH_MAX + 1
        .nocompress
