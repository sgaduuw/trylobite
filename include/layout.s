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
        .equ  P_PROG2,    8               # each process it spawns
        .equ  NPROG,      3
        .equ  P_FREE,     9               # pages from here to RAM_PAGES are free
        .equ  POWER_PA, -2 * PAGE         # power-off register, for firmware

# --- virtual memory ------------------------------------------------------------
# Every address space has the same three regions, by mid-table entry:
#   -1  the direct map: kernel virtual = physical + DMAP, every page
#    0  the kernel, through the shared leaf table; page 0 left unmapped
#   +1  the process's own leaf table
# so a new address space shares everything but its mid table entry +1.

        .equ  DMAP, -SUPER                # direct map offset
        .equ  KOFF, 4 * PAGE              # kernel code and data: physical - KOFF
        .equ  V_HARTS,   -7 * PAGE        # hart controller: every hart's slot
        .equ  V_HART,    -6 * PAGE        # ... and this hart's own
        .equ  V_POWER,   -5 * PAGE        # power-off register
        .equ  V_CONSOLE, -4 * PAGE        # console output register
        .equ  V_USER, SUPER               # every process runs from here
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
        .equ  EDELEG_ALL, 29523           # trits 1..9: every exception to ring 0
        .equ  IDELEG_SOFT, 27             # trit 3: the mailbox doorbell to ring 0
        .equ  IE_TIMER, 3                 # sie trit 1
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

# --- system calls: number in a0, arguments in a1 and a2, result in a0 -------

        .equ  SYS_PUTC,   0               # print code point a1
        .equ  SYS_SEND,   1               # give a2 to process a1: 0 sent,
                                          # -1 its mailbox is full, -2 no such process
        .equ  SYS_RECV,   2               # wait for a message; a0 = the value
        .equ  SYS_YIELD,  3               # let another process run
        .equ  SYS_EXIT,   4               # stop with exit code a1
        .equ  SYS_GETPID, 5               # a0 = this process's number
        .equ  SYS_PUTS,   6               # print the string at a1, whole: 0 done,
                                          # -2 the address is outside the process
        .equ  SYS_SPAWN,  7               # start program a1: its process number,
                                          # -1 no free slot, -2 no such program,
                                          # -3 not enough memory
        .equ  SYS_HART,   8               # a0 = the hart running the caller

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
        .equ  PCB_SIZE,   111
        .equ  PAGES_PER_PROCESS, 4

        .equ  ST_EXITED, 0                # also: a free slot
        .equ  ST_READY,  1                # waiting for a hart
        .equ  ST_RUNNING, 2               # on a hart, or in the kernel for it
        .equ  ST_RECV,   -1               # blocked in SYS_RECV
