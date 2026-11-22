# The boot report: what the kernel found, on its log, before it starts
# init, as BSD and Linux kernels say what they find as they boot. Each
# line starts "trylobite: ", like every other line of the kernel's.

        .compress
# boot_report: the version, then memory, harts, devices and the process
# table, one line each. Hart 0 calls it at boot, after page_init and
# before it spawns init, so the free pages are those init can have.
# Clobbers a0..a2, t0..t5.
boot_report:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    a0, msg_version
        call  kputs

        la    a0, msg_memory           # memory: N pages (T trytes), F free
        call  kputs
        li    a0, RAM_PAGES
        call  kputn
        la    a0, msg_pages
        call  kputs
        li    a0, RAM_PAGES * PAGE
        call  kputn
        la    a0, msg_trytes
        call  kputs
        lw    a0, free_count
        call  kputn
        la    a0, msg_free
        call  kputs

        li    a1, 0                    # harts: how many of the middle nine
        li    a2, -HART_MAX            # are present; start_harts starts them
1:      li    t0, 27
        mul   t0, a2, t0
        li    t1, V_HARTS
        add   t0, t0, t1
        lw    t0, HC_STATE(t0)
        bltz  t0, 2f                   # absent
        addi  a1, a1, 1
2:      addi  a2, a2, 1
        li    t0, HART_MAX
        ble   a2, t0, 1b
        la    a0, msg_harts
        call  kputs
        mv    a0, a1
        call  kputn
        li    a0, '\n'
        call  kputc

        la    a0, msg_irq              # the devices, each on its page
        call  kputs
        li    t0, V_IRQ
        lw    a0, IRQ_SOURCES(t0)
        call  kputn
        la    a0, msg_irq_at
        call  kputs
        li    a1, P_IRQ
        call  boot_page
        la    a0, msg_cons
        call  kputs
        li    a1, P_CONSOLE
        call  boot_page
        la    a0, msg_disk
        call  kputs
        li    t0, V_DISK
        lw    a1, DISK_BLOCKS(t0)
        la    a0, msg_nodisk
        beqz  a1, 3f
        mv    a0, a1
        call  kputn
        la    a0, msg_blocks
3:      call  kputs
        li    a1, P_DISK
        call  boot_page

        la    a0, msg_slots            # the process table, and the programs
        call  kputs                    # the image brings
        li    a0, NPROC
        call  kputn
        la    a0, msg_progs
        call  kputs
        li    a0, NPROG
        call  kputn
        la    a0, msg_image
        call  kputs
        la    a0, msg_init
        call  kputs
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# boot_page: ", at page " a1 and the end of the line. Clobbers a0, t0..t5.
boot_page:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        la    a0, msg_atpage
        call  kputs
        mv    a0, a1
        call  kputn
        li    a0, '\n'
        call  kputc
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret
        .nocompress
