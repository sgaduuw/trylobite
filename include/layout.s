# Constants shared by the firmware, the kernel and user programs.
# Everything that has to agree on an address or a number lives here.
#
# How much RAM the machine has is not here: the kernel reads it at boot
# from the platform's RAM size register (V_POWER + POWER_RAM).

        .equ  PAGE, 19683                 # trytes in a page (3^9)
        .equ  SUPER, 129140163            # trytes in a mid-level superpage (3^17)
        .equ  SUPER_PAGES, 6561           # ... and its pages (3^8)
        .equ  ROOT_SUPER, 847288609443    # trytes in a root-level superpage (3^25)
        .equ  ROOT_PAGES, 43046721        # ... and its pages (3^16)

# --- physical memory -----------------------------------------------------------
# Page 0 is the boot page: a jump to the firmware when the image is loaded
# as a program file, detrytus' boot ROM when it boots from a disk.
# Positive pages are RAM; negative ones devices.

        .equ  P_KDATA,    1               # kernel data and stack
        .equ  P_KCODE,    2               # kernel code, NKCODE pages from here
        .equ  NKCODE,     3               # (include/kernel.s checks it fits)
        .equ  FW_ROOM,    243             # the firmware (firmware/boot.s): the
                                          # last trytes of the last code page,
        .equ  FW_BOOT, (P_KCODE + NKCODE - 1) * PAGE + 9840 - FW_ROOM + 3
                                          # from here, physical and untranslated:
                                          # where every hart starts, and a disk's
                                          # boot record's entry
        .equ  P_BOOTROOT, P_KCODE + NKCODE   # the boot address space's root table
        .equ  P_BOOTMID,  P_BOOTROOT + 1  # ... and its mid table
        .equ  P_KLEAF,    P_BOOTROOT + 2  # the kernel's leaf table, shared by all
        .equ  P_PROG0,    P_BOOTROOT + 3  # program images, as loaded: NPROG of
                                          # them, as the build declares, one after
                                          # another from here, a page each unless
                                          # one says it takes more (IMAGE_PAGES).
                                          # The kernel copies one into fresh pages
                                          # for each process it spawns; the pages
                                          # after the last image are free
        .equ  NPROG_MAX, 27               # programs a build may add
        .equ  IMAGE_PAGES, -9840          # a program image's first word, from its
                                          # page's centre: 0 for an image of one
                                          # page, else how many pages it takes, at
                                          # most 1 + NXPAGE, the next image starting
                                          # after its last. A program of several
                                          # sets it with .org V_USER + IMAGE_PAGES:
                                          # the stack's end of its first page, which
                                          # the kernel reads before the stack grows
        .equ  POWER_PA, -2 * PAGE         # power-off register, for firmware
        .equ  POWER_RAM, 3                # with the power-off register: reads
                                          # how many RAM pages the machine has
        .equ  POWER_CLOCK, 6              # ... the real-time clock: seconds since
                                          # 1970-01-01 UTC; reading it latches
        .equ  POWER_CLOCK_US, 9           # ... the microseconds past that second
                                          # (detrytus platform.md, The real-time
                                          # clock)

# --- virtual memory ------------------------------------------------------------
# Every address space has the same regions, all in root entry 0, a mid
# table, so that every kernel address lies within +-2^31 and is a Rust
# pointer (detrytus docs/rust.md, Pointers):
#  -16..-1  the direct map: kernel virtual = physical + DMAP, mid-level
#           superpages of physical pages centred on 0, SUPER_PAGES, ...
#           15 * SUPER_PAGES, so every page up to MEM_MAX
#    0  the kernel, through the shared leaf table; page 0 left unmapped
#   +1  the process's own leaf table
# so a new address space shares everything but its mid table entry +1.

        .equ  DMAP_SUPERS, 16             # mid entries the direct map takes: -16 to -1
        .equ  DMAP, -DMAP_SUPERS * SUPER  # direct map offset
        .equ  MEM_MAX, 101695             # the last page the direct map reaches:
                                          # RAM past it goes unused
        .assert MEM_MAX == (DMAP_SUPERS - 1) * SUPER_PAGES + (SUPER_PAGES - 1) / 2, "MEM_MAX is not the direct map's last page"
        .assert DMAP - SUPER / 2 > -2147483648, "the direct map reaches below -2^31"
        .equ  KOFF, (P_KCODE + NKCODE + 15) * PAGE   # kernel data and code: virtual =
                                          # physical - KOFF, so pages -19 (data) and
                                          # -18 to -16 (code), just below the
                                          # coprocessor's -15
        .equ  V_DISK,    -9 * PAGE        # block device
        .equ  V_IRQ,     -8 * PAGE        # interrupt controller
        .equ  V_HARTS,   -7 * PAGE        # hart controller: every hart's slot
        .equ  V_HART,    -6 * PAGE        # ... and this hart's own
        .equ  V_POWER,   -5 * PAGE        # power-off register
        .equ  V_CONSOLE, -4 * PAGE        # console output register
        .equ  V_FPU,    -15 * PAGE        # binary floating point coprocessor
                                          # (detrytus platform.md, page -15): every
                                          # process may use it, at its physical
                                          # address, as detrytus ll's code expects
        .equ  FPU_KA, V_FPU + DMAP        # the same, for the kernel: the direct map
        .equ  FPU_REGS, 8                 # A, B, C, R: two words each, at
                                          # FPU_KA - 9, -6, -3, 0, 3, 6, 12, 15
        .equ  CONSOLE_IN, 3               # with V_CONSOLE: the next input code
                                          # point, or one of these when there is none:
        .equ  CONSOLE_EMPTY, -1           # nothing yet: more may come
        .equ  CONSOLE_CLOSED, -2          # nothing more will come
        .equ  P_CONSOLE, -1               # the console's physical page
        .equ  CTRL_C, 3                   # typed while the console has a
                                          # foreground process: kills it
        .equ  V_USER, SUPER               # every process runs from here
        .equ  NXPAGE, 9                   # pages a program file's image may take
                                          # above its own, V_USER + PAGE * k for
                                          # k = 1 to NXPAGE, as spawnw makes them
        .equ  V_BLOCK, V_USER + PAGE * (NXPAGE + 1)   # its block windows, NWIN
                                          # pages from here, each made by SYS_WINDOW
        .equ  USER_GP, V_USER             # every process starts with gp here
        .equ  USER_SP, V_USER             # and sp here: the first push lands just
                                          # below the image, which runs from
                                          # V_USER - 1 up, and the stack grows down
                                          # through the lower half of its page

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

        .equ  DMAP_PTE, PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D   # PPN 0:
                                          # mid entry -16; entry -16 + k adds
                                          # k * SUPER, physical page k * SUPER_PAGES
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

        .equ  P_IRQ, -13                  # the interrupt controller's physical page
        .equ  IRQ_SOURCES, 3              # with V_IRQ: the highest source number
        .equ  IRQ_CLAIM, -3               # with V_IRQ: take a source to serve, 0 if none
        .equ  IRQ_COMPLETE, 0             # with V_IRQ: done serving the source written
        .equ  IRQ_ENABLE, 0               # with V_IRQ + 9*s: +1 lets source s interrupt
        .equ  IRQ_ROUTE, 3                # with V_IRQ + 9*s: the hart it interrupts
        .equ  SRC_CONSOLE, 1              # console input: pending while a read
                                          # would not give CONSOLE_EMPTY
        .equ  SRC_DISK, 2                 # block device: a command has finished
        .equ  SRC_NET, 3                  # network device: a send or receive
                                          # has finished

# The block device (detrytus platform.md, The block device): registers at
# DISK_* from the centre of its page, physical page P_DISK; its driver,
# the disk server, reaches them at V_DEVICE + PAGE * (SRC_DISK - 1). A
# block is one page.
        .equ  P_DISK, -14                 # the block device's physical page
        .equ  NSRC, 3                     # device sources, 1 to NSRC
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

# The network device (detrytus platform.md, The network device):
# registers at NET_* from the centre of its page, physical page P_NET;
# its driver, the network server, reaches them at V_DEVICE + PAGE *
# (SRC_NET - 1). A frame is octets, one per tryte, from the Ethernet
# header on, FRAME_MIN to FRAME_MAX of them.
        .equ  P_NET, -16                  # the network device's physical page
        .equ  NET_KA, P_NET * PAGE + DMAP # its centre, for the kernel's boot
                                          # report: the direct map
        .equ  NET_LINK, -24               # +1 with a link, 0 without
        .equ  NET_MAC_HI, -21             # the interface's address, 24 bits
        .equ  NET_MAC_LO, -18             # ... a half
        .equ  NET_DROPPED, -15            # frames dropped on arrival
        .equ  NET_TX_ADDR, -12            # physical address of the frame to send
        .equ  NET_TX_LEN, -9              # ... its length
        .equ  NET_TX_COMMAND, -6          # NET_SEND sends it
        .equ  NET_TX_STATUS, -3           # NET_BUSY, NET_DONE or NET_FAILED
        .equ  NET_TX_ACK, 0               # any write ends the send's interrupt
        .equ  NET_RX_ADDR, 3              # physical address of a receive buffer
        .equ  NET_RX_SIZE, 6              # ... its size
        .equ  NET_RX_COMMAND, 9           # NET_RECEIVE gives it to the device
        .equ  NET_RX_STATUS, 12           # NET_BUSY until a frame is in it
        .equ  NET_RX_LEN, 15              # the frame's length
        .equ  NET_RX_ACK, 18              # any write ends the receive's interrupt
        .equ  NET_SEND, 1
        .equ  NET_RECEIVE, 1
        .equ  NET_BUSY, 1
        .equ  NET_FAILED, -1
        .equ  FRAME_MIN, 14               # an Ethernet header
        .equ  FRAME_MAX, 1514             # and 1,500 octets of payload

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
        .equ  SYS_GETPID, 5               # a0 = this process's number (for a
                                          # thread, its process's: SYS_GETTID)
        .equ  SYS_PUTS,   6               # print the string at a1, whole: 0 done,
                                          # E_RANGE (outside its page and window)
        .equ  SYS_SPAWN,  7               # start program a1: its process number,
                                          # E_NOSLOT, E_NOPROG, E_NOMEM
        .equ  SYS_HART,   8               # a0 = the hart running the caller,
                                          # -4 to +4
        # 9 was getc: console input is the console server's now
        .equ  SYS_WAIT,  10               # wait for child a1 to end: a0 = how it
                                          # ended, a1 = its exit code or trap cause
        # 11 and 12 were bread and bwrite: the disk is the disk server's now
        .equ  SYS_KILL,  13               # kill(pid, for, sig): send signal a3
                                          # (SIG_ below; 0 only checks) to process
                                          # a1, a child of the caller (a2 =
                                          # FOR_SELF) or, for a driver, of process
                                          # a2: 0 sent, and it ends (before it runs
                                          # again), KILL_CAUGHT (it goes on),
                                          # KILL_ENDED (it had ended already),
                                          # E_NOCHILD, E_INVAL (a3), E_PERM (a2 not
                                          # FOR_SELF from a non-driver); or with
                                          # a2 = KILL_ANY, any process
        .equ  KILL_ENDED, 1               # kill: nothing to end, only to wait for
        .equ  KILL_CAUGHT, 2              # kill: sent, and caught, ignored or
                                          # blocked: the process goes on
        # 14 was foreground: the console server keeps the foreground now
        .equ  SYS_SPAWNW, 15              # start the program file whose first
                                          # block is in block window a1 (see
                                          # EXEC_MAGIC), as a child of the caller
                                          # (a2 = FOR_SELF) or of process a2, whose
                                          # call the caller holds: its process
                                          # number, E_NOSLOT, E_NOPROG, E_NOMEM,
                                          # E_NOPROC. a3 and a4: its arguments,
                                          # a4 trytes at a3 in the parent's
                                          # memory (see ARG_MAX), or a4 = 0 for
                                          # none; E_INVAL (a4 negative or above
                                          # ARG_MAX), E_FAULT (not all there)
        .equ  FOR_SELF, -1                # spawnw, kill: the caller is the parent
        .equ  KILL_ANY, -2                # kill: any process but init (bin/kill):
                                          # E_NOPROC (none, or ended), E_PERM (init)
        # 16 to 22 were the kernel's file calls: files are the file server's now

# Descriptors (docs/kernel.md, Descriptors). Each process has NDESC of them, 0 to
# NDESC - 1, in its record: each names a server and a handle that server
# gave out, or nothing. Only a server puts one there, with give, into a
# process whose call it holds; a process can copy and close its own, and
# a child starts with copies of its parent's, so 0, 1 and 2 (standard
# input, output and error) pass down. A descriptor call (read, write,
# iocall) is a call to the descriptor's server with an IO_ operation, the
# handle in a3 and two arguments in a4 and a5; it returns the reply's
# first word and leaves a1 to a5 as a call does. IO_ operations are
# negative, and SYS_CALL refuses them, so a server that gets one knows
# the kernel brought it from a descriptor it gave out: a handle is a
# capability. When the last descriptor naming a handle goes (close, dup2
# over it, or its process ending), its server gets a NOTE_CLOSED notice.
        .equ  SYS_CLOSE, 16               # close(fd): 0, E_BADF
        .equ  SYS_GIVE,  17               # give(pid, handle): put handle 0 to
                                          # NHANDLE - 1 of the caller's in process
                                          # pid's lowest free descriptor; pid must
                                          # wait for the caller's reply: the
                                          # descriptor, E_MFILE (none free),
                                          # E_NOPROC, E_INVAL (no such handle)
        .equ  SYS_DUP2,  18               # dup2(fd, to): make descriptor to a copy
                                          # of fd, closing what it held: to,
                                          # E_BADF
        .equ  SYS_IOCALL, 19              # iocall(fd, op, x, y): the descriptor
                                          # call op (an IO_ operation) with x and
                                          # y: the server's answer; E_BADF, E_INVAL
                                          # (op not an IO_ operation)
        .equ  SYS_READ,  20               # read(fd, buffer, n): iocall with IO_READ
        .equ  SYS_WRITE, 21               # write(fd, buffer, n): iocall with
                                          # IO_WRITE
        .equ  SYS_FDFLAGS, 22             # fdflags(fd, flags): set descriptor fd's
                                          # flags, FD_NOINHERIT or 0: 0, E_BADF,
                                          # E_INVAL (22 was desc, which let a
                                          # process point a descriptor anywhere)
        .equ  FD_NOINHERIT, 1             # a child does not get a copy: for a
                                          # descriptor a parent keeps for later,
                                          # such as a pipe's other end
        .equ  NDESC,      9               # descriptors per process
        .equ  NHANDLE,   27               # handles a server may give, 0 to 26
        .equ  STDIN,      0
        .equ  STDOUT,     1
        .equ  STDERR,     2
        .equ  IO_READ,   -1               # read(handle, buffer, n): at least 1
                                          # and at most n trytes, waiting for one
                                          # if the server waits; 0 at the end
        .equ  IO_WRITE,  -2               # write(handle, buffer, n): how many
        .equ  IO_LSEEK,  -3               # lseek(handle, offset, whence): the new
                                          # position (files)
        .equ  IO_READDIR, -4              # readdir(handle, buffer): the next
                                          # entry's inode, its name to the buffer;
                                          # 0 at the end (directories)
        .equ  IO_SHUTDOWN, -5             # shutdown(handle): no more writing; the
                                          # other end reads to its end, while this
                                          # one can still read (TCP connections): 0
        .equ  IO_WINSIZE, -6              # winsize(handle): 0, then the rows and
                                          # columns of the terminal behind it in
                                          # the reply's next two words, 0 and 0
                                          # if not known (the console); E_INVAL
                                          # from servers of anything else
        .equ  IO_FIRST,  -6               # the lowest IO_ operation

# Messages for servers (docs/kernel.md, Messages for servers). A message is four words, a2 to
# a5 as sent; a server answers each call with a reply of four words.
        .equ  SYS_CALL,  23               # send a2..a5 to process a1 and wait for
                                          # its reply: a0..a3 = the reply's words;
                                          # E_NOPROC (none, or it ended first), E_SELF
        .equ  SYS_RECEIVE, 24             # wait for a call: a0 = the caller,
                                          # a1..a4 = its words, a5 = its process
                                          # (the caller, unless it is a thread:
                                          # SYS_THREAD); or a0 = FROM_KERNEL,
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
        .equ  NOTE_CLOSED, 2              # ... no descriptor names handle a2 of
                                          # the receiver's any more
        .equ  NOTE_SIGNAL, 3              # ... process a2 notified the receiver
        .equ  NOTE_ALARM, 4               # ... the receiver's alarm went off

# Server names (docs/kernel.md, Names). A server registers a name and the
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
        .equ  SYS_LOOKUP, 29              # lookup(name, how, pid): a0 = the
                                          # server's process number, a1 = its
                                          # version; or E_NOENT (with LOOKUP_NOW,
                                          # nobody has the name), E_NOPROC (with
                                          # LOOKUP_WHILE, process pid ended, or
                                          # never was, first), E_INVAL,
                                          # E_NAMETOOLONG, E_FAULT. With
                                          # LOOKUP_WAIT it sleeps until a server
                                          # registers the name; with LOOKUP_WHILE,
                                          # only while process pid lives (init,
                                          # for a server it started)
        .equ  LOOKUP_NOW, 0
        .equ  LOOKUP_WAIT, 1
        .equ  LOOKUP_WHILE, 2
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

# Drivers (docs/kernel.md, Drivers). A driver is a process that owns a device:
# the device's registers are mapped into it, and its interrupts come to
# it as NOTE_IRQ notices from receive. Only a program from the kernel
# image may drive one: a device that moves memory by itself can write
# any page, kernel or not.
        .equ  SYS_DRIVE, 31               # drive(source): the caller owns device
                                          # source a1 from now on, its registers at
                                          # V_DEVICE + PAGE * (a1 - 1), until it
                                          # ends: 0; E_BUSY (another process drives
                                          # it), E_INVAL (no such source),
                                          # E_PERM (a program file)
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

# What the kernel can say about itself, for system tools (bin/dmesg,
# bin/uname, bin/uptime, bin/free). A buffer of words must be word-aligned
# and lie wholly in the caller's page or one block window.
        .equ  SYS_LOG,   34               # log(buffer, n, from): copy the kernel's
                                          # log, from the a3-th code point it ever
                                          # printed (the oldest it still keeps, if
                                          # that one is gone), at most a2 of them,
                                          # to a1: a0 = how many, a1 = where the
                                          # next read starts; 0 once it has all.
                                          # E_INVAL (a2 negative), E_FAULT
        .equ  LOG_SIZE, PAGE              # code points the log keeps: the last
                                          # page's worth, in a page of its own
        .equ  SYS_INFO,  35               # info(buffer): the SI_ words at a1:
                                          # 0, E_FAULT
        .equ  SI_TIME,    0               # the time CSR: the clock, in ticks
        .equ  SI_TICKS,   3               # timer interrupts taken since boot
        .equ  SI_PAGES,   6               # pages of memory the kernel uses
        .equ  SI_FREE,    9               # ... of them free
        .equ  SI_NPROC,  12               # slots in the process table
        .equ  SI_PROCS,  15               # ... of them in use, zombies included
        .equ  SI_HARTS,  18               # harts present
        .equ  SI_RELEASE, 20              # the kernel's version, as a string of
        .equ  RELEASE_MAX, 8              # at most RELEASE_MAX code points and 0,
                                          # in the trytes from SI_RELEASE
        .equ  SI_BOOTED, 30               # the time of day at boot, in Unix
                                          # seconds (SYS_CLOCK; SYS_STEPCLOCK moves
                                          # it too): uptime in real time is the
                                          # clock now less this
        .equ  SI_LOAD1,  33               # load averages: the processes ready or
        .equ  SI_LOAD5,  36               # running, averaged over 1, 5 and 15
        .equ  SI_LOAD15, 39               # minutes' worth of ticks, in LOAD_ONE
                                          # parts of one (Unix's load averages)
        .equ  SYSINFO,   42               # trytes info fills, from SI_TIME - 1
        .equ  LOAD_ONE,  19683            # a load of one process, in SI_LOAD_ units
        .equ  LOAD_PERIOD, 5000000        # ticks between samples of the load: 5 s
                                          # at a microsecond a tick, as Unix's 5 s
        .equ  LOAD_EXP1, 18109            # each average keeps this share of itself
        .equ  LOAD_EXP5, 19358            # (in LOAD_ONE parts) at each sample:
        .equ  LOAD_EXP15, 19574           # LOAD_ONE * e^(-5 s / 1, 5, 15 min)

# Processes, for bin/ps, bin/top and bin/kill. A process's name is its
# program's, as Unix's comm: what spawnw's first argument names, without
# the directories, or for a program of the kernel image what it says
# with SYS_NAME, as each does as it starts.
        .equ  SYS_PROC,  36               # proc(pid, buffer): the PI_ words of
                                          # process a1 at a2: 0, E_NOPROC (no such
                                          # process: a free slot), E_FAULT
        .equ  PI_STATE,   0               # one of the ST_ values below
        .equ  PI_PARENT,  3               # its parent, or NO_PARENT
        .equ  PI_PAGES,   6               # pages it holds: its four, its image's
                                          # above its own, its block windows and
                                          # its heap; 0 once ended
        .equ  PI_CPU,     9               # ticks it has run in user mode
        .equ  PI_NAME,   11               # its name: PROC_NAME trytes from here
        .equ  PROC_NAME,  9               # PROC_NAME_MAX code points and a 0
        .equ  PROC_NAME_MAX, 8
        .equ  PROCINFO,  21               # trytes proc fills, from PI_STATE - 1
        .equ  SYS_NAME,  37               # name(string): name the caller after the
                                          # string at a1 (its last part after a /,
                                          # PROC_NAME_MAX code points of it): 0,
                                          # E_FAULT
        .equ  SYS_SLEEP, 38               # sleep(until): wait until the time CSR
                                          # reaches a1: 0. Absolute, so a loop
                                          # that adds its period each time keeps
                                          # step (bin/top, bin/sleep)
        .equ  SYS_NOTIFY, 39              # notify(pid): tell process a1, without
                                          # waiting, that the caller wants its
                                          # attention: its receive gives a
                                          # NOTE_SIGNAL notice naming the caller,
                                          # once however often it was notified
                                          # since: 0, E_NOPROC, E_SELF
        .equ  SYS_ALARM, 40               # alarm(until, how): when the time CSR
                                          # reaches a1, the caller's receive gives
                                          # a NOTE_ALARM notice (a2 =
                                          # ALARM_NOTICE), or its process gets
                                          # SIGALRM (ALARM_SIGNAL); a later alarm
                                          # replaces an earlier one, and
                                          # NO_ALARM cancels it: 0
        .equ  NO_ALARM, -1
        .equ  ALARM_NOTICE, 0             # alarm's a2: a NOTE_ALARM notice,
        .equ  ALARM_SIGNAL, 1             # or SIGALRM for the caller's process
        .equ  SYS_BRK,   41               # brk(end): make the caller's heap reach
                                          # end, in whole pages from HEAP_START;
                                          # it never shrinks, and end BRK_QUERY
                                          # only asks: the break, the first
                                          # address past the heap; E_INVAL (end
                                          # outside HEAP_START .. HEAP_START +
                                          # HEAP_MAX * PAGE), E_NOMEM
        .equ  BRK_QUERY, 0
        .equ  SYS_CLOCK, 42               # clock(): the time of day, from the
                                          # machine's real-time clock: a0 = whole
                                          # seconds since 1970-01-01 00:00:00 UTC
                                          # (Unix time; before 1970, negative),
                                          # a1 = microseconds past that second,
                                          # 0 to 999,999. It cannot fail. The
                                          # time CSR (SI_TIME, SYS_SLEEP) stays
                                          # the clock for intervals: ticks since
                                          # boot, which the time of day is not
        .equ  SYS_STEPCLOCK, 43           # stepclock(seconds, micros): move the
                                          # time of day (SYS_CLOCK) by a1 seconds
                                          # and a2 microseconds, -999,999 to
                                          # 999,999, of the same sign as a1 (or
                                          # either when a1 is 0): 0; E_INVAL,
                                          # E_PERM (not a child of init: only the
                                          # servers and /etc/init's programs may).
                                          # The machine's clock stays as it is;
                                          # the kernel keeps the offset (bin/ntpd)
        .equ  SYS_HARTINFO, 49            # hartinfo(hart, buffer): the HI_ words
                                          # of hart a1 at a2, one of the middle
                                          # nine (bin/top): 0, E_NOHART (absent,
                                          # or outside them), E_FAULT
        .equ  HI_TIME,    0               # the time CSR as the call read the rest
        .equ  HI_STARTED, 3               # the time CSR when the kernel started it
        .equ  HI_USER,    6               # ticks it has run processes in user mode
        .equ  HI_IDLE,    9               # ticks it has waited for work (idle);
                                          # the rest since HI_STARTED it was in
                                          # the kernel, or waiting for its lock
        .equ  HARTINFO,  12               # trytes hartinfo fills, from HI_TIME - 1

# Threads (docs/kernel.md, Threads). A thread is a process-table slot of
# its own, with its own registers, state and messages, running in the
# address space of the process that started it, whose pages,
# descriptors, children and exit it shares. Its number is its slot's,
# like a process number: calls, sends and kills reach it by that.
# exit, a fault or a kill in any thread ends the whole process, every
# thread first; thread_exit ends one thread alone, and join gives its
# code to another thread of the process.
        .equ  SYS_THREAD, 44              # thread(entry, stack, arg, tp): start a
                                          # thread of the caller's process at
                                          # entry, with sp = stack, a0 = arg, tp =
                                          # tp and the caller's gp: its number;
                                          # E_NOSLOT
        .equ  SYS_TEXIT, 45               # thread_exit(code): end the calling
                                          # thread alone, for join; E_PERM in a
                                          # process's first thread, which ends
                                          # with exit (it returns nothing else)
        .equ  SYS_JOIN,  46               # join(tid, how): a0 = 0 and a1 = the
                                          # code thread tid gave thread_exit, once
                                          # it has; JOIN_WAIT waits for that,
                                          # JOIN_POLL gives E_BUSY instead.
                                          # E_NOCHILD (not another thread of the
                                          # caller's process, or another join had
                                          # it), E_INVAL (how, or the caller)
        .equ  JOIN_WAIT, 0
        .equ  JOIN_POLL, 1
        .equ  SYS_FUTEX, 47               # futex(address, op, value): the u32 at
                                          # address, four trytes low byte first as
                                          # Rust lays one out, is a lock's word.
                                          # FUTEX_WAIT: sleep there if it is value
                                          # (taken as a u32), until a FUTEX_WAKE:
                                          # 0, E_AGAIN (it is not). FUTEX_WAKE:
                                          # wake at most value threads of the
                                          # caller's process sleeping there: how
                                          # many. E_FAULT, E_INVAL
        .equ  FUTEX_WAIT, 0
        .equ  FUTEX_WAKE, 1
        .equ  SYS_GETTID, 48              # a0 = the calling thread's number; a
                                          # process's first thread's is the
                                          # process's

# Signals (docs/kernel.md, Signals), numbered as Linux numbers them. A
# process has one set of pending signals and one action for each: its
# default (SIG_DFL: end the process, or for SIGCHLD nothing), SIG_IGN,
# or SIG_CATCH, which runs the process's signal entry with a0 = the
# signal and a1 = a SIGFRAME on the stack below sp, in whichever of its
# threads does not block it; the entry ends with sigreturn(frame). Each
# thread has its own mask of blocked signals. A thread blocked in a
# system call (not a server's held call) when a caught signal comes
# gets E_INTR from it, after the handler; trystd calls it again.
# SIGKILL cannot be caught, ignored or blocked.
        .equ  SIGHUP,   1
        .equ  SIGINT,   2                 # Ctrl-C, from the console server
        .equ  SIGQUIT,  3
        .equ  SIGKILL,  9
        .equ  SIGUSR1, 10
        .equ  SIGUSR2, 12
        .equ  SIGPIPE, 13                 # a write to a pipe nobody reads
        .equ  SIGALRM, 14                 # an alarm set with ALARM_SIGNAL
        .equ  SIGTERM, 15                 # bin/kill's default
        .equ  SIGCHLD, 17                 # a child ended; ignored by default
        .equ  NSIG,    31                 # signals are 1 to NSIG - 1: a set of
                                          # them is a word with bit 2^sig for each
        .equ  SYS_SIGACTION, 50           # sigaction(sig, action, entry): what
                                          # signal a1 does from now: SIG_DFL,
                                          # SIG_IGN or SIG_CATCH, which makes a3
                                          # the process's signal entry: the
                                          # action it had; E_INVAL (a1, a2, or
                                          # any but SIG_DFL for SIGKILL)
        .equ  SIG_DFL,   0
        .equ  SIG_IGN,   1
        .equ  SIG_CATCH, 2
        .equ  SYS_SIGMASK, 51             # sigmask(how, set): change the calling
                                          # thread's blocked set: SIG_BLOCK adds
                                          # a2, SIG_UNBLOCK takes it away,
                                          # SIG_SETMASK makes it a2: the set it
                                          # had; E_INVAL. SIGKILL stays unblocked
        .equ  SIG_BLOCK,   0
        .equ  SIG_UNBLOCK, 1
        .equ  SIG_SETMASK, 2
        .equ  SYS_SIGRETURN, 52           # sigreturn(frame): back from a signal's
                                          # entry to where the thread was, with
                                          # its registers and mask as the frame
                                          # at a1 keeps them; E_FAULT if it is not
                                          # all in the caller's memory
        # A signal frame, words from its address up: the registers as the
        # record keeps them (PCB_SP to PCB_T6, word k at PCB_ offset 3k),
        # then these.
        .equ  SF_PC,    81                # where the thread was
        .equ  SF_FPU,   84                # its coprocessor bank, FPU_REGS words
        .equ  SF_MASK,  SF_FPU + 3 * FPU_REGS   # its blocked set
        .equ  SF_SIG,   SF_MASK + 3       # the signal
        .equ  SIGFRAME, SF_SIG + 3        # trytes in a frame

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
#
# An open file is a kernel descriptor (Descriptors, above), so it is
# read and written with SYS_READ and SYS_WRITE, sought with IO_LSEEK and
# listed with IO_READDIR (SYS_IOCALL), and closed with SYS_CLOSE; a child
# inherits it. As descriptor calls: read(buffer, n): how many (0 at the
# end; never past the end of a block), E_BADF (not open for reading),
# E_ISDIR, E_INVAL. write(buffer, n): how many (never past the end of a
# block), E_BADF (not open for writing), E_INVAL, E_NOSPC, E_FBIG.
# lseek(offset, whence): the new position, E_INVAL. readdir(buffer): the
# next entry's inode, its name to the buffer (NAME_MAX + 1 trytes); 0 at
# the end; E_NOTDIR.
        .equ  FS_PROTOCOL, 3              # the calls below, as they are now: a
                                          # change a client would misread moves it on
        .equ  FS_OPEN,    0               # open(path, flags): the caller's lowest
                                          # free descriptor, E_NOENT, E_NOTDIR,
                                          # E_NAMETOOLONG, E_MFILE (no descriptor
                                          # free, or NFILE files open), E_INVAL,
                                          # E_ISDIR (a directory, to write);
                                          # with O_CREAT also E_NOSPC
        # 1 to 4 were close, read, lseek and readdir: descriptor calls now
        .equ  FS_STAT,    5               # stat(path, buffer): 0, the ST_ words at
                                          # the buffer; as open fails
        .equ  FS_SPAWN,   6               # spawnf(path, args, n): starts the
                                          # program file as the caller's child,
                                          # with the n trytes of arguments at args
                                          # in the caller's memory: as spawnw, and
                                          # E_NOEXEC for no program, as open fails
        # 7 was write
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
        .equ  FS_STATFS, 13               # statfs(buffer): how full the disk is,
                                          # as the SF_ words at the (word-aligned)
                                          # buffer: 0, E_FAULT (bin/df)
        .equ  SF_BLOCKS,  0               # blocks in the filesystem,
        .equ  SF_BFREE,   3               # ... of them free
        .equ  SF_INODES,  6               # inodes a file can have (1 to 728),
        .equ  SF_IFREE,   9               # ... of them free
        .equ  STATFS,    12               # trytes statfs fills, from SF_BLOCKS - 1
        .equ  FS_RENAME, 14               # rename(from, to): 0; what from names
                                          # takes the name to, replacing a file of
                                          # that name: E_BUSY (that file is open,
                                          # or from is the root), E_ISDIR (to is a
                                          # directory), E_EXIST (from is a
                                          # directory and to exists, or to is the
                                          # root), E_INVAL (. or .., or a directory
                                          # into itself), E_NOSPC, as open fails
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

# The console comes from the console server, which registers as
# "console" with protocol CONSOLE_PROTOCOL and drives SRC_CONSOLE. A
# console call is a call to it with the CN_ operation in a2 and the
# arguments in a3 and a4; the reply's first word is the result. The
# kernel still prints its own messages, and SYS_PUTC and SYS_PUTS, to the
# console directly: they are its log.
        .equ  CONSOLE_PROTOCOL, 1
        .equ  CN_GETC,    0               # getc(): the next code point typed,
                                          # waiting for one, or GETC_NONE when
                                          # none will come
        .equ  CN_WRITE,   1               # write(buffer, n): print n trytes from
                                          # the caller's memory, whole: n, E_INVAL,
                                          # E_FAULT
        .equ  CN_FOREGROUND, 2            # foreground(pid): give the console to
                                          # child pid of the caller, so that Ctrl-C
                                          # kills it, or to nobody with
                                          # NO_FOREGROUND: 0, E_INVAL. The server
                                          # takes it back when the process ends

# Frames come from the network server, which registers as "net" with
# protocol NET_PROTOCOL and drives SRC_NET. A network call is a call to
# it with the NT_ operation in a2 and the arguments in a3 and a4; the
# reply's first word is the result. A frame in the caller's memory is
# octets, one per tryte, from the Ethernet header on.
        .equ  NET_PROTOCOL, 2
        .equ  NT_SEND,    0               # send(frame, n): put n octets on the
                                          # wire, waiting until they have left: 0;
                                          # E_INVAL (n outside FRAME_MIN to
                                          # FRAME_MAX), E_FAULT, E_IO (no link, or
                                          # an octet that is not one)
        .equ  NT_RECEIVE, 1               # receive(buffer, size): the next frame
                                          # to arrive, waiting for one: its length;
                                          # E_INVAL (size below 1), E_FAULT,
                                          # E_NOROOM (it was longer than size, and
                                          # is gone), E_IO (no link)
        .equ  NT_ADDRESS, 2               # address(): 0, then the interface's
                                          # address in the reply's next two words,
                                          # 24 bits each, high half first
        .equ  NT_LISTEN,  3               # listen(): make the caller the listener,
                                          # in place of any other: 0. For each
                                          # frame that waits with no receive for
                                          # it, the server notifies the listener
                                          # (SYS_NOTIFY) once, and keeps the frame
                                          # for its next receive
        .equ  CN_OPEN,    3               # open(): give the caller a descriptor
                                          # for the console: its lowest free one,
                                          # E_MFILE
        .equ  CONSOLE_HANDLE, 0           # the console's one handle, for IO_READ,
                                          # IO_WRITE and IO_WINSIZE (E_BADF for
                                          # another)

# Packets come from the IP server, which registers as "ip" with protocol
# IP_PROTOCOL and reaches the wire through the network server. A call to
# it has the IP_ operation in a2 and the arguments in a3 to a5; the
# reply's first word is the result. An address is a word: a.b.c.d is
# a * 2^24 + b * 2^16 + c * 2^8 + d.
        .equ  IP_PROTOCOL, 4
        .equ  IP_PING,    0               # ping(address, seq, wait): send an ICMP
                                          # echo request numbered seq (0 to
                                          # 65535) and wait up to wait rounds
                                          # for its reply: the rounds it took;
                                          # E_TIMEDOUT, E_NOROUTE, E_BUSY, E_IO
                                          # (no link), E_INVAL
        .equ  IP_ADDRESS, 1               # address(): 0, then the server's
                                          # address, its prefix length and the
                                          # gateway (0 for none)
        .equ  IP_CONFIG,  2               # config(address, prefix, gateway): set
                                          # them: 0; E_INVAL
        .equ  IP_BIND,    3               # bind(port): give the caller UDP port
                                          # port (1 to 65535), or with 0 a free
                                          # one, in place of any it had: the port;
                                          # E_BUSY (another process has it), E_INVAL
        .equ  IP_SEND,    4               # send(buffer, n): send the datagram at
                                          # buffer, n octets: the address and port
                                          # it goes to (4 and 2 octets), then up to
                                          # 1,472 of data, from the caller's port:
                                          # 0; E_INVAL (no port, n out of range),
                                          # E_FAULT, E_NOROUTE, E_TIMEDOUT (ARP had
                                          # no answer), E_BUSY, E_IO
        .equ  IP_RECEIVE, 5               # receive(buffer, size, wait): the next
                                          # datagram to the caller's port, as send
                                          # takes one but with the sender's address
                                          # and port, waiting up to wait ticks (0
                                          # for ever): its length; E_TIMEDOUT,
                                          # E_NOROOM (longer than size, and gone),
                                          # E_INVAL (no port, size below 6), E_FAULT
        .equ  IP_CONNECT, 6               # connect(address, port): open a TCP
                                          # connection, waiting for the handshake:
                                          # its descriptor; E_REFUSED, E_TIMEDOUT,
                                          # E_NOROUTE, E_NOSPC (every connection in
                                          # use), E_MFILE, E_INVAL, E_IO
        .equ  IP_LISTEN,  7               # listen(port): take connections to TCP
                                          # port port (1 to 65535) for the caller,
                                          # in place of any it listened on; 0 stops:
                                          # 0; E_BUSY (another process listens
                                          # there), E_INVAL
        .equ  IP_ACCEPT,  8               # accept(): wait for a connection to the
                                          # port the caller listens on: a0 = its
                                          # descriptor, a1 = the other end's address,
                                          # a2 its port; E_INVAL (not listening),
                                          # E_MFILE
        .equ  IP_NAMESERVER, 9            # nameserver(address): the address of
                                          # the name server that resolvers ask,
                                          # 10.0.0.3 until set (0 for none), as
                                          # it was; with address 0 or more, set
                                          # it to that, and with NS_KEEP leave
                                          # it: E_INVAL (2^32 or more)
        .equ  NS_KEEP,   -1               # nameserver: only say what it is
# A connection is a descriptor: IO_READ waits for data and gives 0 once
# the other end has closed; IO_WRITE waits until all n octets are queued
# to send. Either is E_RESET once the other end reset the connection, or
# E_TIMEDOUT once it stopped answering. Closing the last descriptor
# closes the connection, after what was written has been delivered.

# Pipes come from the pipe server, which registers as "pipe" with
# protocol PIPE_PROTOCOL. Its ends are descriptors: IO_READ waits for
# something to read, and gives 0 once every write end has closed;
# IO_WRITE waits until all n trytes are in, and is E_PIPE once every
# read end has closed.
        .equ  PIPE_PROTOCOL, 1
        .equ  PP_PIPE,    0               # pipe(): a0 = a read end's descriptor,
                                          # a1 = its write end's; E_NOSPC (every
                                          # pipe in use), E_MFILE (no descriptor
                                          # free; with a1 the read end's, if that
                                          # one was given, to close)

        .equ  E_NOCALL,  -1               # no system call with that number
        .equ  E_FULL,    -1               # send: the receiver's mailbox is full
        .equ  E_NOPROC,  -2               # send: no such process
        .equ  E_RANGE,   -2               # puts: the address is outside the process
        .equ  E_SELF,    -3               # call: a process cannot call itself
        .equ  E_NOSLOT,  -1               # spawn: the process table is full
        .equ  E_NOPROG,  -2               # spawn: no such program; spawnw: no
                                          # window, or no program in it
        .equ  E_NOMEM,   -3               # spawn: not enough free pages
        .equ  GETC_NONE, -1               # console getc: no more input; any negative
                                          # means none
        .equ  E_NOCHILD, -2               # wait: not a child of the caller
        .equ  E_NOHART,  -2               # hartinfo: no such hart running the kernel
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
                                          # drive: the source has a driver;
                                          # ping: another is under way
        .equ  E_NOROOM, -20               # getcwd, receive: the buffer is too small
                                          # (Unix's ERANGE; E_RANGE is puts')
        .equ  E_PERM,   -21               # drive, arm, phys: not allowed
        .equ  E_PIPE,   -22               # pipe write: no read end is open
        .equ  E_TIMEDOUT, -23             # ping: no reply in time
        .equ  E_NOROUTE, -24              # ping: off the network, and no gateway
        .equ  E_REFUSED, -25              # connect: nothing listens on that port
        .equ  E_RESET,  -26               # a connection: the other end reset it
        .equ  E_AGAIN,  -27               # futex: the word is not what was given
        .equ  E_INTR,   -28               # a call a caught signal interrupted

        .equ  O_RDONLY, 0                 # open: the access mode is the flags mod
        .equ  O_WRONLY, 1                 # 3. Add any of O_CREAT (make a file not
        .equ  O_RDWR,   2                 # there), O_TRUNC (empty a file opened for
        .equ  O_CREAT,  3                 # writing) and O_APPEND (write at its end,
        .equ  O_TRUNC,  9                 # each time): ternary digits of 0 or 1,
        .equ  O_APPEND, 27                # so they add as Unix flags OR together
        .equ  NFILE, 27                   # files the file server keeps open, a
        .equ  FD,           9             # record each, its handle the index:
                                          # three words each,
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
        .equ  WAIT_KILLED,  2             # a1 = the signal that ended it

# --- the process table ---------------------------------------------------------
# One record per process, in words. Register r is saved at 3 * (r + 13), so
# sp (r-13) is at 0 and t6 (r13) at 78; r0 has a slot that is never used.

        .equ  NPROC, 27
        .equ  PCB_SP,      0              # saved sp
        .equ  PCB_TP,      6              # saved tp
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
                                          # next runs (ipc.rs wakes a server so)
        .equ  PCB_PENDING, 135            # 1 when a notice may wait for receive
                                          # (PCB_IRQS, PCB_RANG, PCB_CLOSED,
                                          # PCB_SIGNALS, PCB_NOTES): 0 lets it
                                          # skip looking (Proc::rouse sets it)
        .equ  PCB_CALLERS, 138            # how many processes wait in ST_CALL
                                          # for it: 0 lets receive skip looking
        # 141 to 156 were its block windows' pages (PCB_WINS, below, now);
        # threads use them (docs/kernel.md, Threads):
        .equ  PCB_SPACE,  141             # the process whose address space,
                                          # descriptors and children it has: its
                                          # own number, or a thread's process's.
                                          # Every field below is the process's
        .equ  PCB_THREADS, 144            # how many of its threads have not ended
        .equ  PCB_ENDING, 147             # 1 once it is ending: it goes after the
                                          # last of its threads (ST_DYING)
        .equ  PCB_HOW,    150             # ... and how, for its parent's wait,
        .equ  PCB_CODE,   153             # as saved a0 and a1 say
        .equ  PCB_TEXIT,  156             # a thread's own: 1 when it ends alone,
                                          # by thread_exit
        .equ  NWIN,         9             # block windows: window k is at V_BLOCK + PAGE * k
        .equ  V_DEVICE, V_BLOCK + NWIN * PAGE   # a driver's device registers,
                                          # past its windows: source s's at
                                          # V_DEVICE + PAGE * (s - 1)
        .equ  HEAP_LEAF, NXPAGE + NWIN + NSRC + 1   # the heap's first leaf entry,
        .equ  V_HEAP, V_USER + PAGE * HEAP_LEAF     # past the devices' pages:
        .equ  HEAP_START, V_HEAP - 9841   # its first tryte, where brk starts
        .equ  HEAP_MAX, 3281 - HEAP_LEAF  # pages a heap may have: the rest
                                          # of the process's leaf table
        .equ  PCB_HEAP,   132             # pages of heap it has (brk), from
                                          # V_HEAP: their leaf entries say where
        .equ  PCB_SERVES, 159             # 1 once it has called receive: it is told
                                          # of every process that ends (of its
                                          # children's, it is told from the start)
        .equ  PCB_NOTES,  161             # NPROC trytes, 161 to 187 (in the words
                                          # at 162 to 186): 1 for each process
                                          # that has ended since receive last told it
        .equ  PCB_TURN,   189             # receive: the caller it took last
        .equ  PCB_DESCS,  192             # NDESC descriptors, three words each: the
                                          # server plus 1 (0 for none), the handle
                                          # and its flags (FD_NOINHERIT or 0)
        .equ  DESC,         9             # trytes per descriptor
        .equ  PCB_CLOSED, PCB_DESCS + NDESC * DESC - 1   # NHANDLE trytes, 272 to
                                          # 298 (in the words at 273 to 297): 1 for
                                          # each of its handles that no descriptor
                                          # has named since receive last told it
        .equ  PCB_CPU,    PCB_CLOSED + NHANDLE + 1   # ticks it has run in user
                                          # mode (the time CSR, ktrap adds them)
        .equ  PCB_RAN,    PCB_CPU + 3     # time when it last started to run (resume)
        .equ  PCB_NAME,   PCB_RAN + 2     # its name, PROC_NAME trytes, 0-padded:
                                          # the last part of argv[0] (spawnw) or
                                          # what it gave SYS_NAME; empty if neither
        .equ  PCB_FPU,    PCB_NAME + PROC_NAME + 1   # its coprocessor bank, FPU_REGS
                                          # words in FPU_SAVED's order (trap.s)
        .equ  PCB_ALARM,  PCB_FPU + 3 * FPU_REGS   # when its alarm goes off,
                                          # or 0 for none (alarm stores 1 for 0)
        .equ  PCB_RANG,   PCB_ALARM + 3   # 1 once it has gone off, until receive
                                          # tells it
        .equ  PCB_SIGNALS, PCB_RANG + 2   # NPROC trytes (in the words from
                                          # PCB_RANG + 3): 1 for each process that
                                          # has notified it since receive last told it
        .equ  PCB_XPAGES, PCB_SIGNALS + NPROC + 1   # the pages of its image above
                                          # its own, NXPAGE words, 0 for none: page
                                          # k at V_USER + PAGE * k is word k - 1
        .equ  PCB_WINS,   PCB_XPAGES + 3 * NXPAGE   # its block windows' pages,
                                          # NWIN words, 0 for none; so the page
                                          # at V_USER + PAGE * k is word k - 1 of
                                          # PCB_XPAGES for k = 1 to NXPAGE + NWIN
        .equ  PCB_SIGMASK, PCB_WINS + 3 * NWIN   # the signals it blocks
        .equ  PCB_SIGNOTE, PCB_SIGMASK + 3   # 1 when a signal may be there for
                                          # it to take: resume looks (signal.rs)
        .equ  PCB_SIGALRM, PCB_SIGNOTE + 3   # its alarm's how (ALARM_SIGNAL)
        # A process's own, in its first thread's record:
        .equ  PCB_SIGPEND, PCB_SIGALRM + 3   # the signals sent and not yet taken
        .equ  PCB_SIGCATCH, PCB_SIGPEND + 3  # those it catches (SIG_CATCH)
        .equ  PCB_SIGIGN, PCB_SIGCATCH + 3   # those it ignores (SIG_IGN)
        .equ  PCB_SIGENTRY, PCB_SIGIGN + 3   # where caught signals run
        .equ  PCB_SIZE,   PCB_SIGENTRY + 3
        .assert PCB_SIZE % 3 == 0, "PCB_SIZE is not whole words"
        .assert PCB_NOTES + NPROC <= PCB_TURN - 1, "PCB_NOTES runs into PCB_TURN's trytes"
        .assert (PCB_SIGNALS + 1) % 3 == 0, "receive reads PCB_SIGNALS a word at a time"
        .assert (NPROC % 3 == 0) * (NHANDLE % 3 == 0), "receive reads PCB_NOTES and PCB_CLOSED a word at a time"
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
        .equ  ST_FUTEX,  -4               # blocked in FUTEX_WAIT, at its saved a1
                                          # (-4 was ST_GETC, the kernel's console)
        .equ  ST_JOIN,   -5               # blocked in SYS_JOIN, for the thread in
                                          # its saved a1 (-5 was ST_DISK)
        .equ  ST_DYING,  -6               # a process that has ended and waits for
                                          # its threads to go, before its pages do
        .equ  ST_CALL,   -7               # its call waits for PCB_PEER to receive it
        .equ  ST_REPLY,  -8               # PCB_PEER has received its call: waits
                                          # for the reply
        .equ  ST_RECEIVE, -9              # blocked in SYS_RECEIVE
        .equ  ST_LOOKUP, -10              # blocked in SYS_LOOKUP, waiting
        .equ  ST_SLEEP,  -11              # blocked in SYS_SLEEP, until its saved a1
        .equ  NO_FOREGROUND, -1           # CN_FOREGROUND: the console is nobody's
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
        # Words 3 to 8: detrytus' boot record (its docs/platform.md, Booting
        # from a disk): the blocks holding the kernel's image, which the
        # boot ROM loads into RAM pages from BOOT_PAGE and starts at
        # BOOT_ENTRY. A disk without BOOT_MAGIC does not boot.
        .equ  FS_HEAD_BOOT, BLOCK_W0 + 9  # word 3: BOOT_MAGIC
        .equ  BOOT_MAGIC, 20261128
        .equ  BOOT_FIRST, BLOCK_W0 + 12   # word 4: the image's first block
        .equ  BOOT_COUNT, BLOCK_W0 + 15   # word 5: how many blocks it has
        .equ  BOOT_PAGE, BLOCK_W0 + 18    # word 6: the page its first goes to
        .equ  BOOT_ENTRY, BLOCK_W0 + 21   # word 7: where it starts: FW_BOOT
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

# A program file: EXEC_MAGIC, the image's size, then the program's image,
# as assembled to run from V_USER (its first word there, so its first
# tryte at V_USER - 1). The file runs on through as many blocks as it
# needs; the caller of spawnw reads them into consecutive block windows.
# spawnw copies the image into a fresh page at V_USER, and the pages
# above it as far as it reaches (NXPAGE at most); the rest stays 0. The
# magic word's low tryte, its first, is negative, which no text file's
# first tryte is.
        .equ  EXEC_MAGIC, -20261125       # word 0 of a program file's first block
        .equ  EXEC_SIZE, BLOCK_W0 + 3     # word 1: the image's size, in trytes
        .equ  EXEC_IMAGE, BLOCK_W0 + 6    # word 2: the image's first word
        .equ  EXEC_HEAD, 6                # trytes before the image
        .equ  EXEC_MAX, NWIN * PAGE - EXEC_HEAD   # trytes an image may have:
                                          # what NWIN windows hold
        .equ  EXEC_ONE, PAGE - EXEC_HEAD  # ... and what one block holds
        .equ  EXEC_LOW, 9842              # trytes of it in the process's own page,
                                          # from V_USER - 1 to the page's top
        .assert EXEC_MAX <= EXEC_LOW + NXPAGE * PAGE, "an image of EXEC_MAX trytes runs into the block windows"

# A program's arguments (spawnw). The parent gives a block of strings,
# each ended by a 0 (the last may end at the block's end instead): the
# shell gives the command's words, the command first, as Unix's argv.
# spawnw copies them into the lower half of the child's page, which
# nothing else uses, and starts it with a0 = how many (argc) and a1 =
# V_ARGV, a word per argument holding its address, then a 0 word.
        .equ  ARG_MAX, 243                # trytes of arguments, their 0s included
        .equ  V_ARGV, V_USER - 9840       # argv: the page's first word, and
                                          # ARG_MAX + 1 words from there
        .equ  V_ARGS, V_ARGV - 1 + 3 * (ARG_MAX + 1)   # the strings, after it
