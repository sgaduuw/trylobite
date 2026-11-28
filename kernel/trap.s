# Trap entry and exit. While a process runs, sscratch holds its process
# record; in the kernel it holds 0. Swapping sp with sscratch on entry
# therefore yields the record to save into, or 0 for a trap taken inside
# the kernel itself, which is a kernel bug. sscratch is per hart, and the
# process's record is this hart's alone while the process is ST_RUNNING,
# so saving needs no lock.

        .compress
ktrap:
        csrrw sp, sscratch, sp         # sp = process record, sscratch = user sp
        beqz  sp, kpanic
        sw    ra, 3(sp)
        sw    tp, 6(sp)
        sw    gp, 9(sp)
        la    gp, kgp                  # the kernel's gp, before any global
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
        li    t1, FPU_KA               # its coprocessor bank: it may have been
        lw    t0, -9(t1)               # stopped between an operation and its
        sw    t0, PCB_FPU(sp)          # result, and another process may run
        lw    t0, -6(t1)               # here, or it may resume on another hart
        sw    t0, PCB_FPU + 3(sp)
        lw    t0, -3(t1)
        sw    t0, PCB_FPU + 6(sp)
        lw    t0, 0(t1)
        sw    t0, PCB_FPU + 9(sp)
        lw    t0, 3(t1)
        sw    t0, PCB_FPU + 12(sp)
        lw    t0, 6(t1)
        sw    t0, PCB_FPU + 15(sp)
        lw    t0, 12(t1)
        sw    t0, PCB_FPU + 18(sp)
        lw    t0, 15(t1)
        sw    t0, PCB_FPU + 21(sp)
        li    t0, 0                    # csrw from zero would only read
        csrw  sscratch, t0
        mv    s0, sp                   # s0: the current process, from here on
        csrr  t0, time                 # the ticks it ran since resume
        lw    t1, PCB_RAN(s0)
        sub   t0, t0, t1
        lw    t1, PCB_CPU(s0)
        add   t1, t1, t0
        sw    t1, PCB_CPU(s0)
        lw    tp, PCB_HART(s0)         # tp: this hart's number (see resume)
        addi  t1, tp, HART_MAX         # ... and its count of them: only this
        li    t2, 3                    # hart writes its own entries, and it
        mul   t1, t1, t2               # stops counting as in user mode first,
        la    t2, hart_ran             # so hartinfo may count these ticks a
        add   t2, t2, t1               # moment late, never twice
        sw    zero, 0(t2)
        la    t2, hart_user
        add   t1, t1, t2
        lw    t2, 0(t1)
        add   t2, t2, t0
        sw    t2, 0(t1)
        call  klock_take
        la    sp, kstack_top           # the one kernel stack: ours while we hold the lock
        lw    t0, PCB_KILLED(s0)       # killed while it ran: it goes before
        bnez  t0, on_kill              # anything it asked for happens

        csrr  t0, stcause
        li    t1, CAUSE_TIMER
        beq   t0, t1, on_timer
        li    t1, CAUSE_SYSCALL
        beq   t0, t1, on_syscall
        li    t1, CAUSE_EXTERNAL
        beq   t0, t1, on_external
        j     on_fault

# Run the process whose record is in s0: switch to its page table (the
# kernel is mapped, globally, in every one), let the kernel lock go,
# restore its registers and return to ring -1.
#
# Each process has its own ASID, its slot number plus 1, so switching
# needs no fence.vm, except when the slot has been reused since this hart
# last ran it: then this hart's TLB may still hold the old tenant's
# translations for that ASID. spawn counts each slot's tenants in epochs;
# each hart flushes an ASID when it first sees a new epoch for it.
resume:
        lw    t0, PCB_KILLED(s0)       # killed while it waited or was ready
        bnez  t0, on_kill
        lw    t0, PCB_SIGNOTE(s0)      # a signal may be there for it: take
        bnez  t0, on_signal            # it before it runs on (signal.rs)
        la    t0, procs
        sub   t0, s0, t0
        li    t1, PCB_SIZE
        div   t2, t0, t1               # t2: the slot
        la    t0, epochs
        li    t1, 3
        mul   t3, t2, t1
        add   t0, t0, t3
        lw    t4, 0(t0)                # t4: its epoch
        mv    t0, tp
        addi  t0, t0, HART_MAX
        li    t1, NPROC
        mul   t0, t0, t1
        add   t0, t0, t2
        li    t1, 3
        mul   t0, t0, t1
        la    t1, seen
        add   t0, t0, t1               # t0: the epoch this hart last saw
        lw    t1, 0(t0)
        beq   t1, t4, 1f
        sw    t4, 0(t0)
        addi  t2, t2, 1                # the ASID
        fence.vm zero, t2
1:      sw    tp, PCB_HART(s0)         # for ktrap, which cannot read hartid
        la    t0, fpu_owner            # the coprocessor bank: ktrap saved it,
        addi  t1, tp, HART_MAX         # so it is the hart's still unless
        li    t2, 3                    # another process ran here since
        mul   t1, t1, t2
        add   t0, t0, t1
        lw    t1, 0(t0)
        beq   t1, s0, 2f
        sw    s0, 0(t0)
        li    t1, FPU_KA
        lw    t2, PCB_FPU(s0)
        sw    t2, -9(t1)
        lw    t2, PCB_FPU + 3(s0)
        sw    t2, -6(t1)
        lw    t2, PCB_FPU + 6(s0)
        sw    t2, -3(t1)
        lw    t2, PCB_FPU + 9(s0)
        sw    t2, 0(t1)
        lw    t2, PCB_FPU + 12(s0)
        sw    t2, 3(t1)
        lw    t2, PCB_FPU + 15(s0)
        sw    t2, 6(t1)
        lw    t2, PCB_FPU + 18(s0)
        sw    t2, 12(t1)
        lw    t2, PCB_FPU + 21(s0)
        sw    t2, 15(t1)
2:
        csrr  t0, time                 # a whole slice from now: time the
        sw    t0, PCB_RAN(s0)          # (and it runs from now: ktrap counts)
        addi  t0, t0, QUANTUM          # kernel spent on others is not its;
        lw    t1, sleepers             # but no later than the earliest
        beqz  t1, 3f                   # sleeper's time, which only a pick
        lw    t1, next_wake            # wakes: a long slice must not make
        bge   t1, t0, 3f               # sleepers and alarms late
        mv    t0, t1
3:      csrw  stimecmp, t0
        lw    t0, PCB_PTBR(s0)
        csrw  ptbr, t0
        lw    t0, PCB_RETRY(s0)        # its call runs again: a server woken
        bnez  t0, retry                # in receive or lookup (ipc.rs, names.rs)
        addi  t1, tp, HART_MAX         # this hart is in user mode from now
        li    t2, 3                    # (hartinfo)
        mul   t1, t1, t2
        la    t2, hart_ran
        add   t1, t1, t2
        csrr  t0, time
        sw    t0, 0(t1)
        lw    t0, PCB_PC(s0)
        csrw  stpc, t0
        li    t0, -1                   # PR = -1: tret returns to user mode
        csrw  ststatus, t0
        csrw  sscratch, s0
        call  klock_give               # the record is ours: restoring needs no lock
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

# retry: run the system call of the process in s0 again, in its own
# address space, as it reads its arguments from user memory.
retry:
        sw    zero, PCB_RETRY(s0)
        la    sp, kstack_top
        j     syscall_again

on_timer:
        csrr  t0, time
        addi  t0, t0, QUANTUM
        csrw  stimecmp, t0
        lw    t1, ticks
        addi  t1, t1, 1
        sw    t1, ticks
        j     schedule                 # the current process stays ready

# Devices and hot-plug events, on hart 0; the interrupted process carries
# on. A reader that console input woke waits for a hart like any other.
on_external:
        call  rk_hotplug_events
        call  rk_device_irqs
        j     resume

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
        li    t0, WAIT_FAULTED         # for its parent's wait
        sw    t0, PCB_A0(s0)
        csrr  t0, stcause
        sw    t0, PCB_A1(s0)
        j     release

# The process or thread in s0 was killed (kill_pid, or its process
# ending): end it, as wait reports (thread.rs says so and sets a0, a1).
on_kill:
        mv    a0, s0
        call  rk_on_kill
        j     release

# The thread in s0 has a signal to take (PCB_SIGNOTE): rk_signal takes
# one, ending the process or starting its handler, or clears the note;
# then resume looks again.
on_signal:
        mv    a0, s0
        call  rk_signal
        j     resume

# A trap inside the kernel: nothing to save, nowhere to return to.
kpanic:
        la    gp, kgp                  # in case the trap came before ktrap set it
        la    sp, kstack_top
        la    a0, msg_panic
        call  kputs
        csrr  a0, stcause
        call  kputn
        li    a0, 10
        call  kputc
        li    a0, 99
        j     halt
        .nocompress
