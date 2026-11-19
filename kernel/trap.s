# Trap entry and exit. While a process runs, sscratch holds its process
# record; in the kernel it holds 0. Swapping sp with sscratch on entry
# therefore yields the record to save into, or 0 for a trap taken inside
# the kernel itself, which is a kernel bug.

ktrap:
        csrrw sp, sscratch, sp         # sp = process record, sscratch = user sp
        beqz  sp, kpanic
        sw    ra, 3(sp)
        sw    tp, 6(sp)
        sw    gp, 9(sp)
        sw    s8, 12(sp)
        sw    s7, 15(sp)
        sw    s6, 18(sp)
        sw    s5, 21(sp)
        sw    s4, 24(sp)
        sw    s3, 27(sp)
        sw    s2, 30(sp)
        sw    s1, 33(sp)
        sw    s0, 36(sp)
        sw    a0, 42(sp)
        sw    a1, 45(sp)
        sw    a2, 48(sp)
        sw    a3, 51(sp)
        sw    a4, 54(sp)
        sw    a5, 57(sp)
        sw    t0, 60(sp)
        sw    t1, 63(sp)
        sw    t2, 66(sp)
        sw    t3, 69(sp)
        sw    t4, 72(sp)
        sw    t5, 75(sp)
        sw    t6, 78(sp)
        csrr  t0, sscratch
        sw    t0, 0(sp)                # the user's sp
        csrr  t0, stpc
        sw    t0, PCB_PC(sp)
        csrw  sscratch, zero
        mv    s0, sp                   # s0: the current process, from here on
        la    sp, kstack_top

        csrr  t0, stcause
        li    t1, CAUSE_TIMER
        beq   t0, t1, on_timer
        li    t1, CAUSE_SYSCALL
        beq   t0, t1, on_syscall
        j     on_fault

# Run the process whose record is in s0: switch to its page table (the
# kernel is mapped, globally, in every one), restore its registers and
# return to ring -1.
resume:
        lw    t0, PCB_PTBR(s0)
        csrw  ptbr, t0                 # each process has its own ASID: no fence.vm
        lw    t0, PCB_PC(s0)
        csrw  stpc, t0
        li    t0, -1                   # PR = -1: tret returns to user mode
        csrw  ststatus, t0
        csrw  sscratch, s0
        mv    sp, s0
        lw    ra, 3(sp)
        lw    tp, 6(sp)
        lw    gp, 9(sp)
        lw    s8, 12(sp)
        lw    s7, 15(sp)
        lw    s6, 18(sp)
        lw    s5, 21(sp)
        lw    s4, 24(sp)
        lw    s3, 27(sp)
        lw    s2, 30(sp)
        lw    s1, 33(sp)
        lw    s0, 36(sp)
        lw    a0, 42(sp)
        lw    a1, 45(sp)
        lw    a2, 48(sp)
        lw    a3, 51(sp)
        lw    a4, 54(sp)
        lw    a5, 57(sp)
        lw    t0, 60(sp)
        lw    t1, 63(sp)
        lw    t2, 66(sp)
        lw    t3, 69(sp)
        lw    t4, 72(sp)
        lw    t5, 75(sp)
        lw    t6, 78(sp)
        lw    sp, 0(sp)
        tret

on_timer:
        csrr  t0, time
        addi  t0, t0, QUANTUM
        csrw  stimecmp, t0
        la    t0, ticks
        lw    t1, 0(t0)
        addi  t1, t1, 1
        sw    t1, 0(t0)
        j     schedule                 # the current process stays ready

# A process faulted: report it, end it, and carry on with the others.
on_fault:
        la    a0, msg_fault
        call  kputs
        call  current_pid
        call  kputn
        la    a0, msg_cause
        call  kputs
        csrr  a0, stcause
        call  kputn
        la    a0, msg_at
        call  kputs
        csrr  a0, stval
        call  kputn
        li    a0, 10
        call  kputc
        j     release

# A trap inside the kernel: nothing to save, nowhere to return to.
kpanic:
        la    sp, kstack_top
        la    a0, msg_panic
        call  kputs
        csrr  a0, stcause
        call  kputn
        li    a0, 10
        call  kputc
        li    a0, 99
        j     halt
