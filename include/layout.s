# Constants shared by the firmware, the kernel and user programs.
# Everything that has to agree on an address or a number lives here.
#
# RAM_PAGES is not here: it describes the machine the kernel is built
# for, so the build defines it before including include/kernel.s (see demo.s).

        .equ  PAGE, 19683                 # trytes in a page (3^9)
        .equ  SUPER, 129140163            # trytes in a mid-level superpage (3^17)

# --- physical memory -----------------------------------------------------------
# Page 0 is the boot page; positive pages are RAM; negative ones devices.

        .equ  P_KCODE,    1               # kernel code
        .equ  P_KDATA,    2               # kernel data and stack
        .equ  P_BOOTROOT, 3               # the boot address space's root table
        .equ  P_BOOTMID,  4               # ... and its mid table
        .equ  P_KLEAF,    5               # the kernel's leaf table, shared by all
        .equ  P_PROG0,    6               # program images, as loaded: the kernel
        .equ  P_PROG1,    7               # copies one into a fresh page for
        .equ  P_PROG2,    8               # each process it spawns. NPROG of
        .equ  P_PROG3,    9               # them, as the build declares
        .equ  P_PROG4,   10
        .equ  P_PROG5,   11
        .equ  P_PROG6,   12
        .equ  P_PROG7,   13
        .equ  P_PROG8,   14               # (P_FREE, the first free page, is
                                          # include/kernel.s's: it needs NPROG)
        .equ  POWER_PA, -2 * PAGE         # power-off register, for firmware

# --- virtual memory ------------------------------------------------------------
# Every address space has the same three regions, by mid-table entry:
#   -1  the direct map: kernel virtual = physical + DMAP, every page
#    0  the kernel, through the shared leaf table; page 0 left unmapped
#   +1  the process's own leaf table
# so a new address space shares everything but its mid table entry +1.

        .equ  DMAP, -SUPER                # direct map offset
        .equ  KOFF, 4 * PAGE              # kernel code and data: physical - KOFF
        .equ  V_DISK,    -9 * PAGE        # block device
        .equ  V_IRQ,     -8 * PAGE        # interrupt controller
        .equ  V_HARTS,   -7 * PAGE        # hart controller: every hart's slot
        .equ  V_HART,    -6 * PAGE        # ... and this hart's own
        .equ  V_POWER,   -5 * PAGE        # power-off register
        .equ  V_CONSOLE, -4 * PAGE        # console output register
        .equ  CONSOLE_IN, 3               # with V_CONSOLE: the next input code
                                          # point, or one of these when there is none:
        .equ  CONSOLE_EMPTY, -1           # nothing yet: more may come
        .equ  CONSOLE_CLOSED, -2          # nothing more will come
        .equ  CTRL_C, 3                   # typed while the console has a
                                          # foreground process: kills it
        .equ  CONIN_MAX, 81               # code points the kernel holds for getc
        .equ  V_USER, SUPER               # every process runs from here
        .equ  V_BLOCK, V_USER + PAGE      # its block windows, NWIN pages from here,
                                          # each made by SYS_WINDOW
        .equ  USER_GP, V_USER             # every process starts with gp here
        .equ  USER_SP, V_USER + 9843      # just above its page; the first push
                                          # lands at the page's top word

# --- page-table entries (detrytus isa.md 9.3), as values ----------------------

        .equ  PTE_LEAF, 1
        .equ  PTE_PTR,  -1
        .equ  PTE_R,    3
        .equ  PTE_W,    9
        .equ  PTE_X,    27
        .equ  PTE_U,    81
        .equ  PTE_G,    243
        .equ  PTE_A,    729
        .equ  PTE_D,    2187

        .equ  DMAP_PTE, PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D   # PPN 0
        .equ  KLEAF_PTR, PTE_PTR + P_KLEAF * PAGE
        .equ  USER_FLAGS, PTE_LEAF + PTE_R + PTE_W + PTE_X + PTE_U + PTE_A + PTE_D

        .equ  PTBR_BOOT, 1 + P_BOOTROOT * PAGE     # mode +, ASID 0
        # A process's ASID is its number plus 1, so ASID 0 stays the boot space's.

# --- traps ---------------------------------------------------------------------

        .equ  CAUSE_SYSCALL, 4
        .equ  CAUSE_TIMER, -1
        .equ  CAUSE_EXTERNAL, -2          # devices and hot-plug events, on hart 0
        .equ  EDELEG_ALL, 29523           # trits 1..9: every exception to ring 0
        .equ  IDELEG_KERNEL, 36           # trits 2 and 3 to ring 0: devices and
                                          # hot-plug events, and the mailbox doorbell
        .equ  IE_TIMER, 3                 # sie trit 1
        .equ  IE_EXT, 9                   # sie trit 2
        .equ  IE_SOFT, 27                 # sie trit 3
        .equ  QUANTUM, 500                # timer slice, in emulator ticks

# --- harts (detrytus isa.md 5.6, platform.md Harts) ---------------------------
# The kernel runs on harts -HART_MAX .. HART_MAX, the middle nine; others
# the platform may have are left stopped. A slot register of hart h is at
# V_HARTS + 27*h + HC_*, and V_HART + HC_* is the running hart's own.

        .equ  HART_MAX, 4
        .equ  NHART, 2 * HART_MAX + 1
        .equ  HC_STATE, -12               # -1 absent, 0 stopped, +1 running
        .equ  HC_START_PC, -9
        .equ  HC_START_ARG, -6
        .equ  HC_CONTROL, -3              # +1 starts a stopped hart
        .equ  HC_SEND, 0                  # queue a word, 0 or more: rings its doorbell
        .equ  HC_RECEIVE, 3               # own slot: take a word, or MAILBOX_EMPTY
        .equ  MAILBOX_EMPTY, -1           # no message: test the sign, never the number
        .equ  HC_EVENT, -33               # with V_HART: take a hot-plug event,
                                          # kind + 3*hart (kind +1 added, -1 asked
                                          # to leave), 0 if none

# --- devices (detrytus platform.md, Device interrupts) -----------------------
# Every device source is routed to hart 0, which handles hot-plug events
# too. Source s's registers are at V_IRQ + 9*s + IRQ_*.

        .equ  IRQ_CLAIM, -3               # with V_IRQ: take a source to serve, 0 if none
        .equ  IRQ_COMPLETE, 0             # with V_IRQ: done serving the source written
        .equ  IRQ_ENABLE, 0               # with V_IRQ + 9*s: +1 lets source s interrupt
        .equ  IRQ_ROUTE, 3                # with V_IRQ + 9*s: the hart it interrupts
        .equ  SRC_CONSOLE, 1              # console input: pending while a read
                                          # would not give CONSOLE_EMPTY
        .equ  SRC_DISK, 2                 # block device: a command has finished

# The block device (detrytus platform.md, The block device): registers at
# DISK_* from the centre of its page, physical page P_DISK; its driver,
# the disk server, reaches them at V_DEVICE + PAGE * (SRC_DISK - 1). A
# block is one page.
        .equ  P_DISK, -14                 # the block device's physical page
        .equ  NSRC, 2                     # device sources, 1 to NSRC
        .equ  DISK_BLOCKS, -9             # how many blocks; 0 with no disk
        .equ  DISK_BLOCK, -6              # the first block to move
        .equ  DISK_COUNT, -3              # how many blocks
        .equ  DISK_LIST, 0                # physical address of their page numbers
        .equ  DISK_COMMAND, 3             # BLOCK_READ or BLOCK_WRITE
        .equ  DISK_STATUS, 6              # BLOCK_BUSY, BLOCK_DONE or BLOCK_FAILED
        .equ  DISK_ACK, 9                 # any write ends the interrupt
        .equ  BLOCK_READ, 1
        .equ  BLOCK_WRITE, -1
        .equ  BLOCK_FAILED, -1

# --- system calls: number in a0, arguments in a1, a2 and a3, result in a0 ---
#
# A call whose result is a status, or a value that is never negative (a
# process number, a code point), reports failure with a negative number.
# Test the sign, or compare with the names below; never with a bare -1,
# which on this machine is as ordinary a value as any. A call whose result
# can be any word (recv, hart) has no failure to report: a negative result
# there is a value.

        .equ  SYS_PUTC,   0               # print code point a1
        .equ  SYS_SEND,   1               # give a2 to process a1: 0 sent,
                                          # E_FULL, E_NOPROC
        .equ  SYS_RECV,   2               # wait for a message; a0 = the value
        .equ  SYS_YIELD,  3               # let another process run
        .equ  SYS_EXIT,   4               # stop with exit code a1
        .equ  SYS_GETPID, 5               # a0 = this process's number
        .equ  SYS_PUTS,   6               # print the string at a1, whole: 0 done,
                                          # E_RANGE (outside its page and window)
        .equ  SYS_SPAWN,  7               # start program a1: its process number,
                                          # E_NOSLOT, E_NOPROG, E_NOMEM
        .equ  SYS_HART,   8               # a0 = the hart running the caller,
                                          # -4 to +4
        .equ  SYS_GETC,   9               # a0 = the next code point typed, waiting
                                          # for one, or GETC_NONE when none will come
        .equ  SYS_WAIT,  10               # wait for child a1 to end: a0 = how it
                                          # ended, a1 = its exit code or trap cause
        # 11 and 12 were bread and bwrite: the disk is the disk server's now
        .equ  SYS_KILL,  13               # end child a1: 0 done (it ends before
                                          # it runs again), E_NOCHILD
        .equ  SYS_FOREGROUND, 14          # give the console to child a1, or to
                                          # nobody with NO_FOREGROUND: Ctrl-C
                                          # then kills it. 0 done, E_NOCHILD
        .equ  SYS_SPAWNW, 15              # start the program file whose first
                                          # block is in block window a1 (see
                                          # EXEC_MAGIC), as a child of the caller
                                          # (a2 = FOR_SELF) or of process a2, whose
                                          # call the caller holds: its process
                                          # number, E_NOSLOT, E_NOPROG, E_NOMEM,
                                          # E_NOPROC
        .equ  FOR_SELF, -1                # spawnw: the caller is the parent
        # 16 to 22 were the kernel's file calls: files are the file server's now

# Messages for servers (README, Messages). A message is four words, a2 to
# a5 as sent; a server answers each call with a reply of four words.
        .equ  SYS_CALL,  23               # send a2..a5 to process a1 and wait for
                                          # its reply: a0..a3 = the reply's words;
                                          # E_NOPROC (none, or it ended first), E_SELF
        .equ  SYS_RECEIVE, 24             # wait for a call: a0 = the caller,
                                          # a1..a4 = its words; or a0 = FROM_KERNEL,
                                          # a1 = NOTE_ENDED, a2 = a process that ended
        .equ  SYS_REPLY, 25               # answer the call of process a1 with a2..a5:
                                          # 0, E_NOPROC (it is not waiting for you)
        .equ  SYS_COPYIN, 26              # copy a4 trytes from a2 in process a1,
                                          # whose call you hold, to your a3: 0,
                                          # E_NOPROC, E_FAULT (not all in its memory
                                          # or yours)
        .equ  SYS_COPYOUT, 27             # copy a4 trytes from your a2 to a3 in
                                          # process a1: as copyin
        .equ  FROM_KERNEL, -1             # receive: no process sent this
        .equ  NOTE_ENDED, 0               # ... a process ended, its number in a2
        .equ  NOTE_IRQ, 1                 # ... device source a2, which the
                                          # receiver drives, interrupted

# Server names (README, Names). A server registers a name and the
# version of the protocol it speaks once it is ready to take calls; a
# client looks the name up to find its process number, and checks the
# version before it calls. The kernel drops a server's names when it
# ends. A name is a 0-terminated string of 1 to SRV_NAME_MAX code points.
        .equ  SYS_REGISTER, 28            # register(name, version): 0; E_EXIST
                                          # (another process has the name),
                                          # E_NOSPC (NSRV names are taken),
                                          # E_INVAL (version below 1, or an empty
                                          # name), E_NAMETOOLONG, E_FAULT. Again
                                          # with a name it has, a process changes
                                          # its version
        .equ  SYS_LOOKUP, 29              # lookup(name, how): a0 = the server's
                                          # process number, a1 = its version; or
                                          # E_NOENT (with LOOKUP_NOW, nobody has
                                          # the name), E_INVAL, E_NAMETOOLONG,
                                          # E_FAULT. With LOOKUP_WAIT it sleeps
                                          # until a server registers the name
        .equ  LOOKUP_NOW, 0
        .equ  LOOKUP_WAIT, 1
        .equ  SRV_NAME_MAX, 8             # code points in a name; one is left for 0
        .equ  NSRV, 9                     # names the kernel keeps, a record each:
        .equ  SRV,          15            # a record of SRV trytes,
        .equ  SRV_NAME,     -1            # the name, zero-padded, SRV_NAME_MAX + 1
        .equ  SRV_VERSION,   9            # its version, 0 for an unused record,
        .equ  SRV_PID,      12            # and the server
        .assert SRV_NAME + SRV_NAME_MAX + 1 <= SRV_VERSION - 1, "a server name runs into SRV_VERSION's trytes"

        .equ  SYS_WINDOW, 30              # make block window a1, a zeroed page at
                                          # V_BLOCK + PAGE * a1, if the caller has
                                          # none there: 0, E_INVAL (no such
                                          # window), E_NOMEM

# Drivers (README, Drivers). A driver is a process that owns a device:
# the device's registers are mapped into it, and its interrupts come to
# it as NOTE_IRQ notices from receive. Only a program from the kernel
# image may drive one: a device that moves memory by itself can write
# any page, kernel or not.
        .equ  SYS_DRIVE, 31               # drive(source): the caller owns device
                                          # source a1 from now on, its registers at
                                          # V_DEVICE + PAGE * (a1 - 1), until it
                                          # ends: 0; E_BUSY (another process drives
                                          # it), E_INVAL (not a source the kernel
                                          # hands out: only SRC_DISK), E_PERM (a
                                          # program file)
        .equ  SYS_ARM, 32                 # arm(source): let source a1 interrupt
                                          # once; that interrupt masks it again and
                                          # becomes a NOTE_IRQ notice. 0; E_PERM (the
                                          # caller does not drive it). Arm only when
                                          # an interrupt is due, such as after
                                          # starting a command: while a source is
                                          # armed the kernel waits for it rather
                                          # than call the processes stuck
        .equ  SYS_PHYS, 33                # phys(address): a0 = the physical address
                                          # of the caller's address a1, for a device
                                          # to use; E_FAULT (not in its page or a
                                          # block window), E_PERM (it drives nothing)

# Files (docs/filesystem.md) come from the file server, which registers
# as "fs" with protocol FS_PROTOCOL; a program looks it up once, and
# treats a missing server, or another version, as no filesystem. A file
# call is a call to it with the FS_ operation in a2 and the
# arguments in a3..a5, and the reply's first word is the result. A path
# is a 0-terminated string in the caller's memory, from the root with or
# without a leading /. Each fails with E_NOFS (no disk, no filesystem on
# it, or no file server), E_IO (the disk refused a block, or holds
# nonsense), and those taking a path or buffer with E_FAULT (it is not all
# in the caller's page or a block window it has).
        .equ  FS_PROTOCOL, 1              # the calls below, as they are now: a
                                          # change a client would misread moves it on
        .equ  FS_OPEN,    0               # open(path, flags): the lowest free
                                          # descriptor, E_NOENT, E_NOTDIR,
                                          # E_NAMETOOLONG, E_MFILE, E_INVAL,
                                          # E_ISDIR (a directory, to write);
                                          # with O_CREAT also E_NOSPC
        .equ  FS_CLOSE,   1               # close(fd): 0, E_BADF
        .equ  FS_READ,    2               # read(fd, buffer, n): how many (0 at the
                                          # end; never past the end of a block),
                                          # E_BADF (not open for reading),
                                          # E_ISDIR, E_INVAL
        .equ  FS_LSEEK,   3               # lseek(fd, offset, whence): the new
                                          # position, E_BADF, E_INVAL
        .equ  FS_READDIR, 4               # readdir(fd, buffer): the next entry's
                                          # inode, its name to the buffer
                                          # (NAME_MAX + 1 trytes); 0 at the end;
                                          # E_BADF, E_NOTDIR
        .equ  FS_STAT,    5               # stat(path, buffer): 0, the ST_ words at
                                          # the buffer; as open fails
        .equ  FS_SPAWN,   6               # spawnf(path): starts the program file
                                          # as the caller's child: as spawnw, and
                                          # E_NOEXEC for no program, as open fails
        .equ  FS_WRITE,   7               # write(fd, buffer, n): how many (never
                                          # past the end of a block), E_BADF (not
                                          # open for writing), E_INVAL, E_NOSPC,
                                          # E_FBIG
        .equ  FS_UNLINK,  8               # unlink(path): 0, E_ISDIR, E_BUSY (open),
                                          # E_INVAL (. or ..), as open fails
        .equ  FS_MKDIR,   9               # mkdir(path): 0, E_EXIST, E_NOSPC, E_INVAL
        .equ  FS_RMDIR,  10               # rmdir(path): 0, E_NOTEMPTY, E_NOTDIR,
                                          # E_BUSY (open, or the root), E_INVAL
        .equ  FS_CHDIR,  11               # chdir(path): 0, E_NOTDIR, as open fails.
                                          # A path not starting with / starts there
        .equ  FS_GETCWD, 12               # getcwd(buffer, n): the path of the current
                                          # directory, ended with 0, at the buffer:
                                          # its length, E_NOROOM (n too small),
                                          # E_NAMETOOLONG, E_FAULT
        .equ  PATH_MAX, 243               # trytes a path may have, its 0 not counted

# Blocks come from the disk server, which registers as "disk" with
# protocol DISK_PROTOCOL. A disk call is a call to it with the DK_
# operation in a2, the block in a3, and in a4 the centre of a page-sized
# buffer in the caller's memory: a block window's address, V_BLOCK +
# PAGE * k. The reply's first word is 0, or E_NOBLOCK (no such block, or
# no disk), E_IO (the disk refused it), E_FAULT (the buffer is not all
# in the caller's memory) or E_INVAL (no such operation).
        .equ  DISK_PROTOCOL, 1
        .equ  DK_READ,    0               # read(block, buffer)
        .equ  DK_WRITE,   1               # write(block, buffer)

        .equ  E_NOCALL,  -1               # no system call with that number
        .equ  E_FULL,    -1               # send: the receiver's mailbox is full
        .equ  E_NOPROC,  -2               # send: no such process
        .equ  E_RANGE,   -2               # puts: the address is outside the process
        .equ  E_SELF,    -3               # call: a process cannot call itself
        .equ  E_NOSLOT,  -1               # spawn: the process table is full
        .equ  E_NOPROG,  -2               # spawn: no such program; spawnw: no
                                          # window, or no program in it
        .equ  E_NOMEM,   -3               # spawn: not enough free pages
        .equ  GETC_NONE, -1               # getc: no more input; any negative means none
        .equ  E_NOCHILD, -2               # wait: not a child of the caller
        .equ  E_NOBLOCK, -2               # disk calls: no such block, or no disk
        .equ  E_NOFS,    -4               # files: no disk, no filesystem on it, or
                                          # no file server
        .equ  E_NOENT,   -5               # no such file or directory
        .equ  E_NOTDIR,  -6               # a name on the path is not a directory;
                                          # readdir: not a directory
        .equ  E_ISDIR,   -7               # read: a directory
        .equ  E_BADF,    -8               # no such open descriptor
        .equ  E_MFILE,   -9               # open: every descriptor is in use
        .equ  E_INVAL,  -10               # a flag, count or position out of range
        .equ  E_NAMETOOLONG, -11          # a name past NAME_MAX, or a path past
                                          # PATH_MAX
        .equ  E_FAULT,  -12               # a path or buffer outside the caller;
                                          # copyin, copyout: outside either process
        .equ  E_NOEXEC, -13               # spawnf: not a program file
        .equ  E_IO,     -14               # the disk refused (disk calls, files)
        .equ  E_EXIST,  -15               # mkdir, register: the name is taken
        .equ  E_NOSPC,  -16               # no free block or inode, or a full directory
        .equ  E_NOTEMPTY, -17             # rmdir: it holds more than . and ..
        .equ  E_FBIG,   -18               # write: past a file's last block
        .equ  E_BUSY,   -19               # unlink, rmdir: a process has it open,
                                          # or it is one's current directory;
                                          # drive: the source has a driver
        .equ  E_NOROOM, -20               # getcwd: the buffer is too small (Unix's
                                          # ERANGE; E_RANGE is puts')
        .equ  E_PERM,   -21               # drive, arm, phys: not allowed

        .equ  O_RDONLY, 0                 # open: the access mode is the flags mod
        .equ  O_WRONLY, 1                 # 3. Add any of O_CREAT (make a file not
        .equ  O_RDWR,   2                 # there), O_TRUNC (empty a file opened for
        .equ  O_CREAT,  3                 # writing) and O_APPEND (write at its end,
        .equ  O_TRUNC,  9                 # each time): ternary digits of 0 or 1,
        .equ  O_APPEND, 27                # so they add as Unix flags OR together
        .equ  NFD, 8                      # descriptors per process, 0 to 7, kept
        .equ  FD,           9             # by the file server: three words each,
        .equ  FD_INO,       0             # the inode, NO_INO when closed,
        .equ  FD_POS,       3             # the position, in trytes,
        .equ  FD_FLAGS,     6             # and what open was given
        .equ  SEEK_SET, 0                 # lseek: from the start,
        .equ  SEEK_CUR, 1                 # from where it is,
        .equ  SEEK_END, 2                 # from the end
        .equ  ST_INO,   0                 # stat: the inode number, its I_TYPE,
        .equ  ST_TYPE,  3                 # links and size, a word each from
        .equ  ST_LINKS, 6                 # the (word-aligned) address given
        .equ  ST_SIZE,  9
        .equ  STAT,    12                 # trytes stat fills, from ST_INO - 1

# How a child ended, as wait returns it in a0. An exit code can be any
# word, so it comes back in a1, apart from the status; the sign of a0
# tells failure, exit and fault apart.
        .equ  WAIT_EXITED,  0             # a1 = the code it gave exit
        .equ  WAIT_FAULTED, 1             # a1 = the trap cause that ended it
        .equ  WAIT_KILLED,  2             # a1 = 0: kill or Ctrl-C ended it

# --- the process table ---------------------------------------------------------
# One record per process, in words. Register r is saved at 3 * (r + 13), so
# sp (r-13) is at 0 and t6 (r13) at 78; r0 has a slot that is never used.

        .equ  NPROC, 6
        .equ  PCB_GP,      9              # saved gp
        .equ  PCB_A0,     42              # saved a0: system-call number and result
        .equ  PCB_A1,     45
        .equ  PCB_A2,     48
        .equ  PCB_A3,     51
        .equ  PCB_A4,     54
        .equ  PCB_A5,     57
        .equ  PCB_PC,     81
        .equ  PCB_PTBR,   84
        .equ  PCB_STATE,  87              # one of the ST_ values
        .equ  PCB_MAIL,   90              # a waiting message
        .equ  PCB_FULL,   93              # 1 when PCB_MAIL holds one
        .equ  PCB_ROOTPG, 96              # the four pages the process owns
        .equ  PCB_MIDPG,  99
        .equ  PCB_LEAFPG, 102
        .equ  PCB_USERPG, 105
        .equ  PCB_HART,   108             # the hart running it (see resume)
        .equ  PCB_PARENT, 111             # the process that spawned it, or NO_PARENT
        .equ  PCB_PEER,   114             # whom it calls, while ST_CALL or ST_REPLY
        .equ  PCB_KILLED, 117             # 1 once killed: it ends the next time
                                          # the kernel would run it
        .equ  PCB_FILE,   120             # 1 if it runs a program file: it may
                                          # not drive a device
        .equ  PCB_IRQS,   122             # NSRC trytes, 122 and 123 (in the word at
                                          # 123): 1 at PCB_IRQS + s - 1 when source
                                          # s, which it drives, has interrupted
                                          # since receive last told it
        .equ  PCB_RETRY,  129             # 1: run its system call again when it
                                          # next runs (ipc.s wakes a server so)
        .equ  PCB_WINS,   132             # its block windows' pages, a word each,
        .equ  NWIN,         9             # 0 for none: window k is at V_BLOCK + PAGE * k
        .equ  PCB_BLOCKPG, PCB_WINS       # window 0
        .equ  V_DEVICE, V_BLOCK + NWIN * PAGE   # a driver's device registers,
                                          # past its windows: source s's at
                                          # V_DEVICE + PAGE * (s - 1)
        .equ  PCB_SERVES, 159             # 1 once it has called receive: it is told
                                          # of every process that ends
        .equ  PCB_NOTES,  161             # NPROC trytes, 161 to 166 (the words at
                                          # 162 and 165): 1 for each process that
                                          # has ended since receive last told it
        .equ  PCB_TURN,   168             # receive: the caller it took last
        .equ  PCB_SIZE,   171
        .assert PCB_NOTES + NPROC <= PCB_TURN - 1, "PCB_NOTES runs into PCB_TURN's trytes"
        .assert PCB_IRQS + NSRC <= 125, "PCB_IRQS runs into PCB_RETRY's word"
        .equ  PAGES_PER_PROCESS, 4

        .equ  ST_EXITED, 0                # also: a free slot
        .equ  ST_READY,  1                # waiting for a hart
        .equ  ST_RUNNING, 2               # on a hart, or in the kernel for it
        .equ  ST_RECV,   -1               # blocked in SYS_RECV
        .equ  ST_WAIT,   -2               # blocked in SYS_WAIT, for the child in
                                          # its saved a1
        .equ  ST_ZOMBIE, -3               # ended; holds how (saved a0, a1) until
                                          # its parent waits for it
        .equ  ST_GETC,   -4               # blocked in SYS_GETC, until input comes
        # -5 was ST_DISK, waiting for the kernel's disk driver
        .equ  ST_CALL,   -7               # its call waits for PCB_PEER to receive it
        .equ  ST_REPLY,  -8               # PCB_PEER has received its call: waits
                                          # for the reply
        .equ  ST_RECEIVE, -9              # blocked in SYS_RECEIVE
        .equ  ST_LOOKUP, -10              # blocked in SYS_LOOKUP with LOOKUP_WAIT
        .equ  NO_FOREGROUND, -1           # SYS_FOREGROUND: the console is nobody's
        .equ  NO_PARENT, -1               # PCB_PARENT of init and of orphans:
                                          # process numbers are never negative

# --- the filesystem (docs/filesystem.md) ----------------------------------------
# Block 0 holds a header and the map of free blocks, block 1 the inodes;
# every other block holds a file's or a directory's data. Offsets are in
# trytes from a block's centre, as a program's
# block window address them. Memory is centred (detrytus isa.md 5.2): a
# block's words sit at -9840, -9837, ..., 9840, and its trytes run from
# -9841 to 9841.

        .equ  BLOCK_W0, -9840             # a block's first word
        .equ  BLOCK_T0, -9841             # ... and its first tryte, where
                                          # a file's data starts
        .equ  FS_HEAD_MAGIC, BLOCK_W0     # word 0: FS_MAGIC
        .equ  FS_HEAD_VERSION, BLOCK_W0 + 3   # word 1: FS_VERSION
        .equ  FS_HEAD_BLOCKS, BLOCK_W0 + 6    # word 2: blocks in the filesystem
        .equ  FS_MAGIC, 20261121          # any word but 0: a blank disk is not one
        .equ  FS_VERSION, 2
        .equ  FS_MAP, BLOCK_T0 + 27       # after 9 words: one tryte per block,
        .equ  MAP_FREE, 0                 # free or used, to the end of block 0
        .equ  MAP_USED, 1
        .equ  FS_MAX_BLOCKS, 19656        # as many as the map has trytes

        .equ  FS_INODE_BLOCK, 1           # the inode table, a block of its own
        .equ  FS_INODES, 729              # inodes 0 to 728; 0 is never used
        .equ  INODE, 27                   # trytes each, from BLOCK_W0 + INODE * i;
        .equ  I_TYPE, 0                   # its words, from its first: what it is
        .equ  I_LINKS, 3                  # directory entries naming it
        .equ  I_SIZE, 6                   # its size, in trytes
        .equ  I_DIRECT, 9                 # NDIRECT data blocks, one word each,
        .equ  NDIRECT, 5                  # the first ones of the file
        .equ  I_INDIRECT, 24              # a block of the next ones' numbers
        .equ  NO_BLOCK, 0                 # a data block that is not there: it
                                          # reads as zeros (block 0 never is one)
        .equ  T_FREE, 0                   # I_TYPE: an unused inode
        .equ  T_FILE, 1                   # a regular file
        .equ  T_DIR, 2                    # a directory
        .equ  ROOT_INO, 1                 # the root directory, /

        .equ  DIRENT, 21                  # trytes per directory entry; a
        .equ  DIRENTS, 937                # block holds DIRENTS, from BLOCK_W0
        .equ  D_NAME, -1                  # the name, 18 trytes, zero-padded
        .equ  D_INO, 18                   # its inode, NO_INO when unused
        .equ  NO_INO, 0
        .equ  NAME_MAX, 17                # code points in a name; one is left for 0

# A program file: EXEC_MAGIC, then the program's image, as assembled to
# run from V_USER (its first word there, so its first tryte at V_USER - 1).
# spawnw copies the image into a fresh page at V_USER; the rest stays 0.
# The magic word's low tryte, its first, is negative, which no text file's
# first tryte is.
        .equ  EXEC_MAGIC, -20261121       # word 0 of a program file's first block
        .equ  EXEC_IMAGE, BLOCK_W0 + 3    # word 1: the image's first word
        .equ  EXEC_MAX, 9843              # trytes an image may have: V_USER - 1
                                          # to the top of the page, stack included
