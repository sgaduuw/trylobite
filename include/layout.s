# Constants shared by the firmware, the kernel and user programs.
# Everything that has to agree on an address or a number lives here.

        .equ  PAGE, 19683                 # trytes in a page (3^9)

# --- physical memory -----------------------------------------------------------
# Page 0 is the boot page; positive pages are RAM; negative ones devices.

        .equ  P_KCODE,  1                 # kernel code
        .equ  P_KDATA,  2                 # kernel data and stack
        .equ  P_AS0,    4                 # process 0: root, mid, leaf tables
        .equ  P_AS1,    7                 # process 1: root, mid, leaf tables
        .equ  P_USER0, 10                 # process 0's code, data and stack
        .equ  P_USER1, 11                 # process 1's code, data and stack
        .equ  POWER_PA, -2 * PAGE         # power-off register, for firmware

# --- virtual memory ------------------------------------------------------------
# The kernel sits in negative addresses, user programs in positive ones,
# and virtual page 0 stays unmapped so null pointers fault.

        .equ  KOFF, 4 * PAGE              # kernel virtual = physical - KOFF
        .equ  V_POWER,   -5 * PAGE        # power-off register
        .equ  V_CONSOLE, -4 * PAGE        # console output register
        .equ  V_USER, PAGE                # every process starts here
        .equ  USER_SP, PAGE + 9843        # just above its page; the first push
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

        # ptbr: mode +, an ASID per process, the root table's page
        .equ  PTBR0, 1 + 3 * 1 + P_AS0 * PAGE
        .equ  PTBR1, 1 + 3 * 2 + P_AS1 * PAGE

# --- traps ---------------------------------------------------------------------

        .equ  CAUSE_SYSCALL, 4
        .equ  CAUSE_TIMER, -1
        .equ  EDELEG_ALL, 29523           # trits 1..9: every exception to ring 0
        .equ  QUANTUM, 500                # timer slice, in emulator ticks

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

# --- the process table ---------------------------------------------------------
# One record per process, in words. Register r is saved at 3 * (r + 13), so
# sp (r-13) is at 0 and t6 (r13) at 78; r0 has a slot that is never used.

        .equ  NPROC, 2
        .equ  PCB_A0,    42               # saved a0: system-call number and result
        .equ  PCB_A1,    45
        .equ  PCB_A2,    48
        .equ  PCB_PC,    81
        .equ  PCB_PTBR,  84
        .equ  PCB_STATE, 87               # one of the ST_ values
        .equ  PCB_MAIL,  90               # a waiting message
        .equ  PCB_FULL,  93               # 1 when PCB_MAIL holds one
        .equ  PCB_SIZE,  96

        .equ  ST_EXITED, 0
        .equ  ST_READY,  1
        .equ  ST_RECV,   -1               # blocked in SYS_RECV
