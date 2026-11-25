# The boot address space, built at assembly time: what the firmware hands
# the kernel. It has the direct map and the kernel but no process; spawn
# builds each process's tables at run time (kernel/mm.s).

        .section tables, P_BOOTROOT * PAGE
        .word PTE_PTR + P_BOOTMID * PAGE           # root entry 0 -> mid table

        .org  P_BOOTMID * PAGE - 3
        .word DMAP_PTE                             # mid -1: the direct map
        .word KLEAF_PTR                            # mid 0: the kernel

# The kernel's leaf table, shared by every address space: kernel pages are
# global, so one copy serves them all.
        .org  P_KLEAF * PAGE - 45
        .word PTE_LEAF + PTE_R + PTE_W + PTE_U + PTE_G + PTE_A + PTE_D - 15 * PAGE # -15 coprocessor
        .org  P_KLEAF * PAGE - 27
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 14 * PAGE # -9 block device
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 13 * PAGE # -8 interrupts
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 3 * PAGE  # -7 hart slots
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 4 * PAGE  # -6 this hart
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 2 * PAGE  # -5 power
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - PAGE      # -4 console
        .word PTE_LEAF + PTE_R + PTE_X + PTE_G + PTE_A + P_KCODE * PAGE    # -3 code
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D + P_KDATA * PAGE  # -2 data
