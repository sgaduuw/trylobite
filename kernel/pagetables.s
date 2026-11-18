# Page tables, built at assembly time. Each process has a root, a mid and
# a leaf table, one page each; every address used here falls under root
# entry 0 and mid entry 0, so one leaf table per process covers it all.
#
#   virtual page  -5  power-off register   kernel, global
#                 -4  console              kernel, global
#                 -3  kernel code          kernel, global
#                 -2  kernel data, stack   kernel, global
#                  1  the process itself   user
#
# Both processes run at virtual page 1, on different physical pages.

        .equ  KCODE_PTE, PTE_LEAF + PTE_R + PTE_X + PTE_G + PTE_A + P_KCODE * PAGE
        .equ  KDATA_PTE, PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D + P_KDATA * PAGE
        .equ  DEVICE, PTE_LEAF + PTE_R + PTE_W + PTE_G + PTE_A + PTE_D
        .equ  USER, PTE_LEAF + PTE_R + PTE_W + PTE_X + PTE_U + PTE_A + PTE_D

        .section tables, P_AS0 * PAGE
        # process 0: root at the centre of page P_AS0
        .word PTE_PTR + (P_AS0 + 1) * PAGE         # root entry 0 -> mid table
        .org  (P_AS0 + 1) * PAGE
        .word PTE_PTR + (P_AS0 + 2) * PAGE         # mid entry 0 -> leaf table
        .org  (P_AS0 + 2) * PAGE - 15
        .word DEVICE - 2 * PAGE                    # leaf -5: power off
        .word DEVICE - PAGE                        # leaf -4: console
        .word KCODE_PTE                            # leaf -3
        .word KDATA_PTE                            # leaf -2
        .org  (P_AS0 + 2) * PAGE + 3
        .word USER + P_USER0 * PAGE                # leaf 1

        # process 1: the same kernel mappings, its own page 1
        .org  P_AS1 * PAGE
        .word PTE_PTR + (P_AS1 + 1) * PAGE
        .org  (P_AS1 + 1) * PAGE
        .word PTE_PTR + (P_AS1 + 2) * PAGE
        .org  (P_AS1 + 2) * PAGE - 15
        .word DEVICE - 2 * PAGE
        .word DEVICE - PAGE
        .word KCODE_PTE
        .word KDATA_PTE
        .org  (P_AS1 + 2) * PAGE + 3
        .word USER + P_USER1 * PAGE
