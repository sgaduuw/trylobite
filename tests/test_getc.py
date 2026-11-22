"""Console input: getc from the console server, and the convention that
a negative result means no character. The console server is process 1,
so the programs init spawns are 2 and 3."""

from tests.kernel import EXIT, GETC, SPAWN_BOTH, run

GETC_NONE = -1  # include/layout.s

# Print every character read until getc says there is none, then exit
# with what it said. The loop tests the sign, as programs should.
ECHO = f"""
1:      {GETC}
        bltz  a0, 2f
        mv    a1, a0
        li    a0, SYS_PUTC
        sys
        j     1b
2:      mv    a1, a0
        {EXIT}
"""

# Count the characters read, yielding after each so that two readers
# take turns, then exit with the count.
COUNT = f"""
        li    s0, 0
1:      {GETC}
        bltz  a0, 2f
        addi  s0, s0, 1
        li    a0, SYS_YIELD
        sys
        j     1b
2:      mv    a1, s0
        {EXIT}
"""


def test_getc_returns_the_input_in_order_then_none():
    result = run(ECHO, input="tryte\nby tryte\n", console=True)
    assert "tryte\nby tryte\n" in result.console
    assert result.code_of(0) == GETC_NONE


def test_getc_without_input_returns_none_at_once():
    result = run(ECHO, console=True)
    assert result.code_of(0) == GETC_NONE


def test_nul_is_a_character_not_the_end():
    result = run(COUNT, input="a\0b", console=True)
    assert result.code_of(0) == 3


def test_beyond_the_basic_plane_a_code_point_is_still_one_character():
    # U+1D11E needs more than one tryte's worth of trits; it still comes
    # back as one code point, and positive.
    result = run(ECHO, input="\U0001d11e!", console=True)
    assert "\U0001d11e!" in result.console
    assert result.code_of(0) == GETC_NONE


def test_two_readers_share_the_input_and_no_character_is_read_twice():
    text = "balanced ternary " * 6
    result = run(SPAWN_BOTH, COUNT, COUNT, input=text, console=True)
    counts = (result.code_of(2), result.code_of(3))
    assert sum(counts) == len(text)
    assert min(counts) > 0  # both really read some
