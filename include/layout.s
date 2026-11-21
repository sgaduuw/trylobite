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
        .equ  P_FREE, P_PROG0 + NPROG     # pages from here to RAM_PAGES are free
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
        .equ  V_USER, SUPER               # every process runs from here
        .equ  V_BLOCK, V_USER + PAGE      # its block window, once it uses the disk
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
        .equ  HC_SEND, 0                  # queue a word: rings its doorbell
        .equ  HC_RECEIVE, 3               # own slot: take a word, 0 if none
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
# V_DISK + DISK_*. A block is one page.
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

# --- system calls: number in a0, arguments in a1 and a2, result in a0 -------
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
        .equ  SYS_BREAD, 11               # read block a1 into the block window, at
                                          # V_BLOCK: 0 done, E_NOBLOCK, E_NOMEM, E_IO
        .equ  SYS_BWRITE, 12              # write the block window to block a1: the
                                          # same results

        .equ  E_NOCALL,  -1               # no system call with that number
        .equ  E_FULL,    -1               # send: the receiver's mailbox is full
        .equ  E_NOPROC,  -2               # send: no such process
        .equ  E_RANGE,   -2               # puts: the address is outside the process
        .equ  E_NOSLOT,  -1               # spawn: the process table is full
        .equ  E_NOPROG,  -2               # spawn: no such program
        .equ  E_NOMEM,   -3               # spawn: not enough free pages
        .equ  GETC_NONE, -1               # getc: no more input; any negative means none
        .equ  E_NOCHILD, -2               # wait: not a child of the caller
        .equ  E_IO,      -1               # bread, bwrite: the disk refused
        .equ  E_NOBLOCK, -2               # bread, bwrite: no such block, or no disk

# How a child ended, as wait returns it in a0. An exit code can be any
# word, so it comes back in a1, apart from the status; the sign of a0
# tells failure, exit and fault apart.
        .equ  WAIT_EXITED,  0             # a1 = the code it gave exit
        .equ  WAIT_FAULTED, 1             # a1 = the trap cause that ended it

# --- the process table ---------------------------------------------------------
# One record per process, in words. Register r is saved at 3 * (r + 13), so
# sp (r-13) is at 0 and t6 (r13) at 78; r0 has a slot that is never used.

        .equ  NPROC, 6
        .equ  PCB_A0,     42              # saved a0: system-call number and result
        .equ  PCB_A1,     45
        .equ  PCB_A2,     48
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
        .equ  PCB_BLOCKPG, 114            # its block window's page, or 0 for none
        .equ  PCB_SIZE,   117
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
        .equ  ST_DISK,   -5               # blocked in SYS_BREAD or SYS_BWRITE, its
                                          # command in its saved a2 and block in a1
        .equ  NO_PARENT, -1               # PCB_PARENT of init and of orphans:
                                          # process numbers are never negative
