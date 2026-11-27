# The boot address space, built at assembly time: what the firmware hands
# the kernel. It has the direct map and the kernel but no process; spawn
# builds each process's tables at run time (kernel/mm.s).

        .section tables, P_BOOTROOT * PAGE
        .word PTE_PTR + P_BOOTMID * PAGE           # root entry 0 -> mid table

        .org  P_BOOTMID * PAGE - 3 * DMAP_SUPERS   # mid -16 to -1: the direct map
        .word DMAP_PTE, DMAP_PTE + SUPER, DMAP_PTE + 2 * SUPER, DMAP_PTE + 3 * SUPER
        .word DMAP_PTE + 4 * SUPER, DMAP_PTE + 5 * SUPER, DMAP_PTE + 6 * SUPER, DMAP_PTE + 7 * SUPER
        .word DMAP_PTE + 8 * SUPER, DMAP_PTE + 9 * SUPER, DMAP_PTE + 10 * SUPER, DMAP_PTE + 11 * SUPER
        .word DMAP_PTE + 12 * SUPER, DMAP_PTE + 13 * SUPER, DMAP_PTE + 14 * SUPER, DMAP_PTE + 15 * SUPER
        .assert DMAP_SUPERS == 16, "the boot mid table lists 16 direct-map entries"
        .word KLEAF_PTR                            # mid 0: the kernel

# The kernel's leaf table, shared by every address space: kernel pages are
# global, so one copy serves them all.
        .assert KOFF == 20 * PAGE, "the kernel's leaf table maps data at -19 and code at -18 to -16"
        .assert (P_KDATA == 1) * (P_KCODE == 2) * (NKCODE == 3), "the kernel's leaf table maps one data page and three code pages"
        .org  P_KLEAF * PAGE - 57
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D + P_KDATA * PAGE  # -19 data
        .word PTE_LEAF + PTE_R + PTE_X + PTE_G + PTE_A + P_KCODE * PAGE          # -18 code
        .word PTE_LEAF + PTE_R + PTE_X + PTE_G + PTE_A + (P_KCODE + 1) * PAGE    # -17 code
        .word PTE_LEAF + PTE_R + PTE_X + PTE_G + PTE_A + (P_KCODE + 2) * PAGE    # -16 code
        .word PTE_LEAF + PTE_R + PTE_W + PTE_U + PTE_G + PTE_A + PTE_D - 15 * PAGE # -15 coprocessor
        .org  P_KLEAF * PAGE - 27
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 14 * PAGE # -9 block device
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 13 * PAGE # -8 interrupts
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 3 * PAGE  # -7 hart slots
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 4 * PAGE  # -6 this hart
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - 2 * PAGE  # -5 power
        .word PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D - PAGE      # -4 console
