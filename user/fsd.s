# The file server (docs/filesystem.md): a process that owns the
# filesystem on the disk and answers other processes' calls to open,
# read and look at its files. init starts it first, so it is FS_PID.
#
# A file call is a SYS_CALL to FS_PID with the FS_ operation in a2 and
# its arguments in a3..a5 (include/layout.s); the reply's first word is
# the result. The server takes one call at a time: it copies a path in
# with copyin, and data or a name out with copyout, while it holds the
# call. Each process's descriptors are kept here, and dropped when the
# kernel says the process has ended.
#
# Blocks come through the server's block windows, NWIN of them, used as
# a cache: the least recently used goes when another block is needed.
# The server assumes nothing else writes the disk while it runs. A call
# needs at most four blocks at once (block 0, the inode table, an
# indirect block and a data block), so none it holds is evicted under it.
#
# Not a program on its own: a build includes it in a program's section.
# Its labels all start with fs_, since it shares the build's symbols.

        .compress
        .gp   USER_GP

fs_start:
        li    sp, USER_SP              # a fresh stack for every call: a
        li    a0, SYS_RECEIVE          # call that fails just replies
        sys
        li    t0, FROM_KERNEL
        beq   a0, t0, fs_notice
        mv    s0, a0                   # s0: the caller
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
        mv    a2, a0
        mv    a1, s0
        li    a0, SYS_REPLY
        sys
        j     fs_start

# A process ended: close what it had open.
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
        j     fs_start

# open(path, flags): the lowest free descriptor, at the start of the
# file or directory path names.
fs_open:
        call  fs_enter
        lw    t0, fs_a2
        li    t1, O_RDONLY
        bne   t0, t1, fs_inval
        lw    a0, fs_a1
        call  fs_namei
        mv    s2, a0                   # s2: the inode
        li    a1, 0
        call  fs_fdaddr                # a0: descriptor 0's record
        li    t2, 0                    # t2: its number
1:      lw    t0, FD_INO(a0)
        beqz  t0, 2f
        addi  a0, a0, FD
        addi  t2, t2, 1
        li    t0, NFD
        blt   t2, t0, 1b
        li    a0, E_MFILE
        j     fs_reply
2:      sw    s2, FD_INO(a0)
        sw    zero, FD_POS(a0)
        lw    t0, fs_a2
        sw    t0, FD_FLAGS(a0)
        mv    a0, t2
        j     fs_reply

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
# child, from its first block in one of the server's windows.
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
        j     fs_reply
9:      li    a0, E_NOEXEC
        j     fs_reply

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
# disk refuses it (E_NOFS in fs_enter), or E_NOMEM when the kernel has no
# page for a new window. Clobbers a0..a3 and t0..t6.
fs_bget:
        lw    t3, fs_clock
        addi  t3, t3, 1
        sw    t3, fs_clock             # t3: now
        addi  t6, a0, 1                # t6: what a window holding it says
        la    t1, fs_wblk
        li    t0, 0                    # t0: the window looked at
        li    t4, 0                    # t4: the one to take, if none has it
        lw    t5, fs_wuse              # t5: when that was last used
1:      lw    t2, 0(t1)
        beq   t2, t6, 4f               # it is here
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
        mv    a2, t4
        mv    t4, t1
        mv    t5, a0
        mv    a1, a0
        li    a0, SYS_BREAD
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
# the root; slashes before, between and after names do not count.
# Replies E_FAULT, E_NAMETOOLONG, E_NOTDIR, E_NOENT, or as fs_bget does.
# Clobbers a0..a4, t0..t6 and s2..s8.
fs_namei:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  fs_getpath
        la    s2, fs_path              # s2: where we are in the path
        li    s3, ROOT_INO             # s3: the inode reached
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
        mv    a0, s3                   # look it up in directory s3
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
9:      mv    a0, s3
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

        .equ  FS_NOPS, 7               # the operations, by FS_ number
fs_ops: .word fs_open, fs_close, fs_read, fs_lseek, fs_readdir, fs_stat, fs_spawn
        .assert FS_SPAWN == FS_NOPS - 1, "fs_ops must list every FS_ operation"

fs_a1:  .word 0                        # the call's arguments
fs_a2:  .word 0
fs_a3:  .word 0
fs_entering: .word 0                   # 1 while fs_enter reads block 0
fs_clock: .word 0                      # counts fs_bget calls
fs_wblk: .words NWIN                   # the block each window holds, plus 1;
fs_wuse: .words NWIN                   # 0 for none. When each was last used
fs_statbuf: .words STAT / 3
fs_fds: .words NPROC * NFD * FD / 3    # each process's descriptors
        .equ  FS_ZEROS, 243            # trytes of zeros a hole is read from
fs_zeros: .zero FS_ZEROS
fs_name: .zero NAME_MAX + 1
fs_path: .zero PATH_MAX + 1
        .nocompress
