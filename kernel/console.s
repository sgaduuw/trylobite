# Kernel console output, which is also the kernel's log: every code point
# the kernel prints is kept in a page of its own (log_base), the last
# LOG_SIZE of them, for SYS_LOG (info.s) to read back, as Unix's dmesg
# reads the kernel's message buffer. Each helper clobbers only a0 and
# t0..t5.

        .compress
# kout: print code point t0 and keep it in the log, once boot has given
# the log its page. Clobbers t2, t3, t5.
kout:
        li    t5, V_CONSOLE
        sw    t0, 0(t5)
        lw    t2, log_base
        beqz  t2, 1f
        lw    t3, log_pos
        addi  t5, t3, 1
        sw    t5, log_pos
        li    t5, LOG_SIZE
        rem   t3, t3, t5               # log_pos is never negative
        add   t2, t2, t3
        st    t0, 0(t2)
1:      ret

# kputc: print code point a0.
kputc:
        mv    t0, a0
        j     kout                     # which returns to our caller

# kputs: print the 0-terminated string at a0.
kputs:
        mv    t4, ra
1:      lt    t0, 0(a0)
        beqz  t0, 2f
        call  kout
        addi  a0, a0, 1
        j     1b
2:      jalr  zero, 0(t4)

# kputn: print a0 in decimal.
kputn:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        mv    t3, a0
        bgez  t3, 1f
        li    t0, '-'
        call  kout
        neg   t3, a0
1:      la    t4, numbuf_end
        li    t1, 10
2:      rem   t2, t3, t1
        addi  t2, t2, '0'
        addi  t4, t4, -1
        st    t2, 0(t4)
        div   t3, t3, t1
        bnez  t3, 2b
        la    t1, numbuf_end
3:      lt    t0, 0(t4)
        call  kout
        addi  t4, t4, 1
        bne   t4, t1, 3b
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret

# log_init: give the log its page. Hart 0 calls it at boot, after
# rk_page_init and before the boot report, so the report is in the log.
# Clobbers a0, t0..t5.
log_init:
        addi  sp, sp, -3
        sw    ra, 0(sp)
        call  rk_take_page             # not cleared: log reads only what
                                       # was printed
        li    t0, PAGE
        mul   t0, a0, t0
        li    t1, DMAP - 9841          # the page's first tryte
        add   t0, t0, t1
        sw    t0, log_base
        lw    ra, 0(sp)
        addi  sp, sp, 3
        ret
        .nocompress
