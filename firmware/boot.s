# Ring +1 firmware, in the boot page. It hands every exception and the
# mailbox doorbell to the kernel, points translation at the boot address
# space, and enters the kernel in ring 0.
#
# Every hart runs it. Hart 0 starts here at reset with a0 = 0 and enters
# the kernel at kentry; the kernel starts the others here with a0 = the
# kernel address to enter instead. Each enters with its hart number in
# a1, since hartid is a ring +1 CSR the kernel cannot read.

boot:
        li    t0, EDELEG_ALL
        csrw  edeleg, t0
        li    t0, IDELEG_SOFT
        csrw  ideleg, t0
        la    t0, fw_trap
        csrw  mtvec, t0
        li    t0, PTBR_BOOT            # the boot address space: kernel only
        csrw  ptbr, t0
        li    t0, kentry               # a virtual address: the kernel's run address
        beqz  a0, 1f
        mv    t0, a0
1:      csrw  mtpc, t0
        csrr  a1, hartid
        li    t0, 0                    # PR = 0: tret enters ring 0
        csrw  mtstatus, t0
        tret

# A trap the kernel did not take reaches ring +1: power off with its cause
# as the exit code, so it cannot pass unnoticed.
fw_trap:
        csrr  a0, mtcause
        li    t0, POWER_PA
        sw    a0, 0(t0)
