# Kernel console output. Each helper clobbers only a0 and t0..t5.

        .compress
# kputc: print code point a0.
kputc:
        li    t5, V_CONSOLE
        sw    a0, 0(t5)
        ret

# kputs: print the 0-terminated string at a0.
kputs:
        li    t5, V_CONSOLE
1:      lt    t0, 0(a0)
        beqz  t0, 2f
        sw    t0, 0(t5)
        addi  a0, a0, 1
        j     1b
2:      ret

# kputn: print a0 in decimal.
kputn:
        li    t5, V_CONSOLE
        mv    t3, a0
        bgez  t3, 1f
        li    t0, '-'
        sw    t0, 0(t5)
        neg   t3, t3
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
        sw    t0, 0(t5)
        addi  t4, t4, 1
        bne   t4, t1, 3b
        ret
        .nocompress
