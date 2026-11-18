# Ring +1 firmware, in the boot page. It hands every exception to the
# kernel, points translation at process 0's page table (which also maps
# the kernel), and enters the kernel in ring 0.

boot:
        li    t0, EDELEG_ALL
        csrw  edeleg, t0
        la    t0, fw_trap
        csrw  mtvec, t0
        li    t0, PTBR0
        csrw  ptbr, t0
        li    t0, kentry - KOFF        # the kernel's virtual entry point
        csrw  mtpc, t0
        li    t0, 0                    # PR = 0: tret enters ring 0
        csrw  mtstatus, t0
        tret

# A trap the kernel did not take reaches ring +1: power off with its cause
# as the exit code, so it cannot pass unnoticed.
fw_trap:
        csrr  a0, mtcause
        li    t0, POWER_PA
        sw    a0, 0(t0)
