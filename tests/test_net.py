"""The network server (user/netd.s): it drives the network device
(detrytus platform.md, The network device) and gives frames to and takes
them from its clients. A frame is octets, one per tryte. The tests give
the device a loopback link, which hands every frame sent straight back."""

from tests.kernel import EXIT, exit_with, start, wait_for
from tests.kernel import run as run_kernel

PAYLOAD = "hello, wire"
FRAME_LEN = 14 + len(PAYLOAD)
# A frame to everyone from the interface's own address, of the local
# experimental type 88B5, then the payload: octets, one per tryte.
FRAME = f"""
frame:  .tryte 255, 255, 255, 255, 255, 255, 2, 0, 0, 0, 0, 1, 0x88, 0xB5
        .ascii "{PAYLOAD}"
"""
BUFFER = "buf:    .zero 1800                     # a frame read in ends in a 0"


def run(*args, link="loop", **kwargs):
    """A run with the network server, process 1, started first."""
    return run_kernel(*args, net=True, link=link, **kwargs)


def net_call(op: str, a3: str = "zero", a4: str = "zero") -> str:
    """A call to the network server; a0 is how it went."""
    return f"""
        CALL_NET
        li    a2, {op}
        mv    a3, {a3}
        mv    a4, {a4}
        sys"""


SEND = f"""
        la    s1, frame
        li    s2, {FRAME_LEN}
        {net_call("NT_SEND", "s1", "s2")}"""

RECEIVE = f"""
        la    s1, buf
        li    s2, 1800
        {net_call("NT_RECEIVE", "s1", "s2")}"""


def test_a_frame_sent_comes_back_on_a_loopback_link():
    result = run(f"""
        {SEND}
        bnez  a0, 9f
        {RECEIVE}
        mv    s3, a0
        li    a0, SYS_PUTS             # the payload, after the header
        la    a1, buf + 14
        sys
        mv    a0, s3
9:      {exit_with("a0")}
{FRAME}
{BUFFER}
""")
    assert result.code_of(0) == FRAME_LEN, result.console
    assert PAYLOAD in result.console
    # Nobody waits on the network once init is done: the machine stops.
    assert result.exit_code == 0


def test_address_gives_the_interface_address_in_two_halves():
    result = run(f"""
        {net_call("NT_ADDRESS")}
        bnez  a0, 9f
        li    t0, 131072               # 02:00:00
        bne   a1, t0, 8f
        li    t0, 1                    # 00:00:01
        bne   a2, t0, 8f
        li    a0, 0
        j     9f
8:      li    a0, 1
9:      {exit_with("a0")}
""")
    assert result.code_of(0) == 0, result.console


def test_a_reader_waits_for_the_next_frame():
    # Program 1 reads first and waits; init then sends.
    reader = f"""
        {RECEIVE}
        mv    s3, a0
        li    a0, SYS_PUTS
        la    a1, buf + 14
        sys
        {exit_with("s3")}
{BUFFER}
"""
    result = run(
        f"""
        {start(1)}
        mv    s5, a0
        li    s4, 3000                 # time for the reader to wait first
1:      addi  s4, s4, -1
        bnez  s4, 1b
        {SEND}
        mv    s4, a0
        {wait_for("s5")}
        {exit_with("s4")}
{FRAME}
""",
        reader,
    )
    assert result.code_of(0) == 0, result.console
    assert result.code_of(2) == FRAME_LEN, result.console
    assert PAYLOAD in result.console


def test_a_frame_too_long_for_the_buffer_is_refused_and_gone():
    result = run(f"""
        {SEND}
        la    s1, buf
        li    s2, 10
        {net_call("NT_RECEIVE", "s1", "s2")}
        {exit_with("a0")}
{FRAME}
{BUFFER}
""")
    assert result.code_of(0) == result.image.symbols["E_NOROOM"], result.console


def test_bad_lengths_are_refused():
    result = run(f"""
        la    s1, frame
        li    s2, FRAME_MIN - 1
        {net_call("NT_SEND", "s1", "s2")}
        mv    s3, a0
        li    s2, FRAME_MAX + 1
        {net_call("NT_SEND", "s1", "s2")}
        mv    s4, a0
        {net_call("NT_RECEIVE", "s1", "zero")}
        mv    s5, a0
        li    t0, E_INVAL
        li    a0, 0
        bne   s3, t0, 8f
        bne   s4, t0, 8f
        beq   s5, t0, 9f
8:      li    a0, 1
9:      {exit_with("a0")}
{FRAME}
""")
    assert result.code_of(0) == 0, result.console


def test_without_a_link_sends_and_receives_fail():
    result = run(
        f"""
        {SEND}
        mv    s3, a0
        {RECEIVE}
        li    t0, E_IO
        li    a1, 0
        bne   a0, t0, 8f
        beq   s3, t0, 9f
8:      li    a1, 1
9:      {EXIT}
{FRAME}
{BUFFER}
""",
        link=None,
    )
    assert result.code_of(0) == 0, result.console


def test_an_armed_device_does_not_keep_the_machine_on_for_nobody():
    # A driver arms the network device and waits in receive; once init is
    # done nobody waits on anything, so a frame could serve nobody, and the
    # machine stops rather than waiting for one.
    driver = """
        li    a0, SYS_DRIVE
        li    a1, SRC_NET
        sys
        li    a0, SYS_ARM
        li    a1, SRC_NET
        sys
1:      li    a0, SYS_RECEIVE
        sys
        j     1b
"""
    result = run_kernel(
        f"""
        {start(1)}
        li    s4, 3000                 # time for the driver to arm
1:      addi  s4, s4, -1
        bnez  s4, 1b
        li    a1, 0
        {EXIT}
""",
        driver,
        link="loop",
    )
    assert "all processes exited" in result.console, result.console
