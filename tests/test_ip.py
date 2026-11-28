"""The IP server (user/ipd.s): ARP and ICMP echo over IPv4, above the
network server. On a loopback link every frame it sends comes back to
it, so pinging its own address runs the whole exchange: an ARP request
and its reply, an echo request and its reply, each sent and taken in."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tests.kernel import run as run_kernel
from tests.test_files import L, report, said

OURS = (10 << 24) + 2  # 10.0.0.2, the server's address until told otherwise
WAIT = 100_000  # rounds a ping may take: each frame waits up to 1,000 for the link


def run(*args, link="loop", **kwargs):
    """A run with the network and IP servers, processes 1 and 2."""
    return run_kernel(*args, ip=True, link=link, **kwargs)


def ip_call(op: str, *words: int | str) -> str:
    def load(w: int | str) -> str:
        # A label's address, or a number or constant (in capitals) itself.
        return "la" if str(w).isidentifier() and not str(w).isupper() else "li"

    regs = "".join(f"\n        {load(w)}    a{3 + i}, {w}" for i, w in enumerate(words))
    return f"""
        CALL_IP
        li    a2, {op}{regs}
        sys"""


def ping(address: int, seq: int = 1, wait: int = WAIT) -> str:
    """A ping; a0 is 1 for a reply (the rounds it took vary), else the error."""
    return (
        ip_call("IP_PING", address, seq, wait)
        + """
        blez  a0, 1f
        li    a0, 1
1:"""
    )


def test_a_ping_to_its_own_address_comes_back():
    result = run(report(ping(OURS), ping(OURS, 2)))
    assert said(result) == [1, 1], result.console
    # Nobody waits once init is done, though the server listens: it stops.
    assert result.exit_code == 0


def test_address_says_the_defaults_and_config_changes_them():
    other = (192 << 24) + (168 << 16) + 7
    result = run(
        report(
            ip_call("IP_ADDRESS") + "\n        mv a0, a1",
            ip_call("IP_ADDRESS") + "\n        mv a0, a2",
            ip_call("IP_ADDRESS") + "\n        mv a0, a3",
            ip_call("IP_CONFIG", other, 16, 0),
            ip_call("IP_ADDRESS") + "\n        mv a0, a1",
            ping(other),
            ping(OURS),  # not ours any more, and off the network: no way there
            ip_call("IP_CONFIG", 0, 16, 0),
            ip_call("IP_CONFIG", other, 33, 0),
        )
    )
    assert said(result) == [
        OURS,
        24,
        OURS - 1,
        0,
        other,
        1,
        L["E_NOROUTE"],
        L["E_INVAL"],
        L["E_INVAL"],
    ], result.console


def test_a_ping_nobody_answers_runs_out_of_time():
    # 10.0.0.9 is on the network, but nobody answers ARP for it.
    result = run(report(ping(OURS + 7, wait=20_000), ping(OURS)))
    assert said(result) == [L["E_TIMEDOUT"], 1], result.console


def test_a_ping_through_the_gateway_waits_for_the_gateway():
    # 8.8.8.8 is off the network: the request goes to 10.0.0.1, which
    # nobody answers for.
    result = run(report(ping(8 << 24 | 8 << 16 | 8 << 8 | 8, wait=20_000)))
    assert said(result) == [L["E_TIMEDOUT"]], result.console


def test_a_bad_ping_is_refused():
    result = run(
        report(
            ping(0),
            ping(1 << 32),
            ping(OURS, -1),
            ping(OURS, 65536),
            ping(OURS, 1, 0),
        )
    )
    assert said(result) == [L["E_INVAL"]] * 5, result.console


def test_with_no_link_a_ping_fails():
    result = run(report(ping(OURS)), link=None)
    assert said(result) == [L["E_IO"]], result.console


def test_ping_in_the_shell_says_each_reply():
    result = run_image(
        assemble_file(ROOT / "shell.s"),
        input="ping 10.0.0.2 2\nping 10.0.0.9 1\nping 10.0.0\nping 10.0.0.2 x\n",
        disk=bin_disk(),
        link="loop",
        max_steps=10_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert re.fullmatch(
        r"\$ ping 10\.0\.0\.2 2\n"
        r"reply from 10\.0\.0\.2: seq 1, \d+\.\d{3} ms\n"
        r"reply from 10\.0\.0\.2: seq 2, \d+\.\d{3} ms\n"
        r"\$ ping 10\.0\.0\.9 1\n"
        r"no reply from 10\.0\.0\.9: seq 1\n"
        r"sh: exit 1\n"
        r"\$ ping 10\.0\.0\n"
        r"ping: 10\.0\.0: not a host name\n"
        r"sh: exit 1\n"
        r"\$ ping 10\.0\.0\.2 x\n"
        r"usage: ping HOST \[COUNT\]\n"
        r"sh: exit 2\n"
        r"\$ \n",
        out,
    ), out


IFCONFIG_USAGE = (
    r"usage: ifconfig \[ADDRESS/PREFIX \[GATEWAY\]\], "
    r"or ifconfig nameserver ADDRESS\n"
)


def test_ifconfig_says_and_sets_the_address():
    result = run_image(
        assemble_file(ROOT / "shell.s"),
        input="ifconfig\nifconfig 192.168.1.7/16\nifconfig\n"
        "ifconfig 192.168.1.7/16 0.0.0.0\nifconfig\nping 192.168.1.7 1\n"
        "ifconfig 10.0.0.3/33\nifconfig 0.0.0.0/8\n"
        "ifconfig nameserver 0.0.0.0\nifconfig\nifconfig nameserver 9.9.9.9\n"
        "ifconfig\nifconfig nameserver x\n",
        disk=bin_disk(),
        link="loop",
        max_steps=10_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert re.fullmatch(
        r"\$ ifconfig\ninet 10\.0\.0\.2/24 gateway 10\.0\.0\.1 nameserver 10\.0\.0\.3\n"
        r"\$ ifconfig 192\.168\.1\.7/16\n"
        r"\$ ifconfig\n"
        r"inet 192\.168\.1\.7/16 gateway 10\.0\.0\.1 nameserver 10\.0\.0\.3\n"
        r"\$ ifconfig 192\.168\.1\.7/16 0\.0\.0\.0\n"
        r"\$ ifconfig\ninet 192\.168\.1\.7/16 gateway none nameserver 10\.0\.0\.3\n"
        r"\$ ping 192\.168\.1\.7 1\nreply from 192\.168\.1\.7: seq 1, \d+\.\d{3} ms\n"
        r"\$ ifconfig 10\.0\.0\.3/33\n" + IFCONFIG_USAGE + r"sh: exit 2\n"
        r"\$ ifconfig 0\.0\.0\.0/8\nifconfig: the IP server refused\nsh: exit 1\n"
        r"\$ ifconfig nameserver 0\.0\.0\.0\n"
        r"\$ ifconfig\ninet 192\.168\.1\.7/16 gateway none nameserver none\n"
        r"\$ ifconfig nameserver 9\.9\.9\.9\n"
        r"\$ ifconfig\ninet 192\.168\.1\.7/16 gateway none nameserver 9\.9\.9\.9\n"
        r"\$ ifconfig nameserver x\n" + IFCONFIG_USAGE + r"sh: exit 2\n"
        r"\$ \n",
        out,
    ), out


# --- UDP ---------------------------------------------------------------------


def datagram(label: str, port: int, text: str, address: int = OURS) -> str:
    """A datagram as a client gives one: address, port, then the data."""
    octets = [address >> 24 & 255, address >> 16 & 255, address >> 8 & 255]
    octets += [address & 255, port >> 8, port & 255]
    return f"""
{label}: .tryte {", ".join(map(str, octets))}
        .ascii "{text}"
{label}_end:"""


def send(label: str) -> str:
    return ip_call("IP_SEND", label, f"{label}_end - {label}")


def tryte_at(label: str, offset: int) -> str:
    return f"""
        la    t0, {label}
        lt    a0, {offset}(t0)"""


def word_at(label: str, offset: int, n: int) -> str:
    """The big-endian number in n octets at label + offset."""
    loads = "".join(
        f"""
        li    t2, 256
        mul   a0, a0, t2
        lt    t2, {offset + i}(t0)
        add   a0, a0, t2"""
        for i in range(n)
    )
    return f"""
        la    t0, {label}
        li    a0, 0{loads}"""


RBUF = "rbuf:   .zero 1600"


def test_the_echo_service_sends_a_datagram_back():
    result = run(
        report(
            ip_call("IP_BIND", 0),
            send("hello"),
            ip_call("IP_RECEIVE", "rbuf", 1600, WAIT),
            word_at("rbuf", 0, 4),  # from our own address,
            word_at("rbuf", 4, 2),  # port 7,
            tryte_at("rbuf", 6),  # with what was sent
            tryte_at("rbuf", 10),
            data=datagram("hello", 7, "hello") + "\n" + RBUF,
        )
    )
    assert said(result) == [49152, 0, 11, OURS, 7, ord("h"), ord("o")], result.console


def test_a_datagram_reaches_the_process_on_its_port():
    # Program 1 binds port 9000 and waits for a datagram; init, on port
    # 5000, sends it one, and exits with the sender port the child saw.
    child = (
        ip_call("IP_BIND", 9000)
        + ip_call("IP_RECEIVE", "rbuf", 1600, 0)
        + """
        mv    s1, a0
        li    a0, SYS_PUTS
        la    a1, rbuf + 6
        sys"""
        + word_at("rbuf", 4, 2)
        + f"""
        li    t0, 100
        mul   a1, a0, t0
        add   a1, a1, s1
        li    a0, SYS_EXIT
        sys
        .gp   USER_GP
{RBUF}
"""
    )
    init = f"""
        .gp   USER_GP
        {ip_call("IP_BIND", 5000)}
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s5, a0
        li    s4, 20000                # time for the child to bind and wait
1:      addi  s4, s4, -1
        bnez  s4, 1b
        {send("dgram")}
        mv    s4, a0
        li    a0, SYS_WAIT
        mv    a1, s5
        sys
        mv    a1, s4
        li    a0, SYS_EXIT
        sys
{datagram("dgram", 9000, "ternary")}
"""
    result = run(init, "        .gp   USER_GP\n" + child)
    assert result.code_of(0) == 0, result.console
    assert result.code_of(3) == 5000 * 100 + 6 + 7, result.console
    assert "ternary" in result.console


def test_datagrams_wait_for_receives_oldest_first():
    result = run(
        report(
            ip_call("IP_BIND", 4000),
            send("one"),
            send("two"),
            ip_call("IP_RECEIVE", "rbuf", 1600, WAIT),
            tryte_at("rbuf", 6),
            ip_call("IP_RECEIVE", "rbuf", 7, WAIT),  # too small: and gone
            ip_call("IP_RECEIVE", "rbuf", 1600, 20_000),  # nothing more
            data=datagram("one", 4000, "a") + datagram("two", 4000, "bb") + RBUF,
        )
    )
    assert said(result) == [
        4000,
        0,
        0,
        7,
        ord("a"),
        L["E_NOROOM"],
        L["E_TIMEDOUT"],
    ], result.console


def test_udp_calls_refuse_what_cannot_be_done():
    result = run(
        report(
            send("hello"),  # no port yet
            ip_call("IP_RECEIVE", "rbuf", 1600, 0),
            ip_call("IP_BIND", 65536),
            ip_call("IP_BIND", -1),
            ip_call("IP_BIND", 7),
            ip_call("IP_SEND", "hello", 5),  # shorter than an address and port
            ip_call("IP_RECEIVE", "rbuf", 5, 0),
            send("silent"),  # nobody answers ARP for 10.0.0.9
            send("far"),  # off the network, through the gateway: the same
            ip_call("IP_CONFIG", OURS, 24, 0),
            send("far"),  # and now no way there
            data=datagram("hello", 7, "hello")
            + datagram("silent", 7, "x", OURS + 7)
            + datagram("far", 7, "x", 8 << 24)
            + RBUF,
        )
    )
    assert said(result) == [
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_INVAL"],
        7,
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_TIMEDOUT"],
        L["E_TIMEDOUT"],
        0,
        L["E_NOROUTE"],
    ], result.console


def test_nc_sends_to_the_echo_service_and_prints_what_comes_back():
    result = run_image(
        assemble_file(ROOT / "shell.s"),
        input="echo hello udp | nc -u 10.0.0.2 7\nnc -u 10.0.0.2\n"
        "echo x | nc -u 10.0.0.9 7\nnc -u -l 0\n",
        disk=bin_disk(),
        link="loop",
        max_steps=10_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    usage = "usage: nc [-u] HOST PORT, or nc [-u] -l PORT\nsh: exit 2\n"
    assert out == (
        "$ echo hello udp | nc -u 10.0.0.2 7\nhello udp\n"
        f"$ nc -u 10.0.0.2\n{usage}"
        "$ echo x | nc -u 10.0.0.9 7\nnc: no answer\nsh: exit 1\n"
        f"$ nc -u -l 0\n{usage}"
        "$ \n"
    ), out


# --- TCP ---------------------------------------------------------------------


def io(call: str, fd: str, buffer: str = "rbuf", n: int | str = 1600) -> str:
    """read or write on the descriptor in the register or word fd."""
    load = f"mv    a1, {fd}" if fd.startswith("s") else f"lw    a1, {fd}"
    return f"""
        li    a0, {call}
        {load}
        la    a2, {buffer}
        li    a3, {n}
        sys"""


def close(fd: str) -> str:
    return f"""
        li    a0, SYS_CLOSE
        mv    a1, {fd}
        sys"""


def test_a_connection_to_its_own_port_carries_data_both_ways():
    # One process listens, connects to itself and accepts: s1 is the
    # connecting end, s2 the accepted one.
    result = run(
        report(
            ip_call("IP_LISTEN", 9000),
            ip_call("IP_CONNECT", OURS, 9000) + "\n        mv    s1, a0",
            ip_call("IP_ACCEPT")
            + "\n        mv    s2, a0\n        mv    s3, a1\n        mv    s4, a2",
            "        mv    a0, s3",  # from our own address
            "        mv    a0, s4",  # and the connecting end's port
            io("SYS_WRITE", "s1", "hello", 5),
            io("SYS_READ", "s2"),
            tryte_at("rbuf", 4),
            io("SYS_WRITE", "s2", "hello", 2),
            io("SYS_READ", "s1"),
            close("s1"),
            io("SYS_READ", "s2"),  # the end
            close("s2"),
            data='hello: .ascii "hello"\n' + RBUF,
        )
    )
    # Init has no standard input or output: the descriptors are 0 and 1.
    assert said(result) == [
        0,
        0,
        1,
        OURS,
        49152,
        5,
        5,
        ord("o"),
        2,
        2,
        0,
        0,
        0,
    ], result.console
    assert result.exit_code == 0


def test_tcp_calls_refuse_what_cannot_be_done():
    result = run(
        report(
            ip_call("IP_ACCEPT"),  # not listening
            ip_call("IP_LISTEN", 65536),
            ip_call("IP_LISTEN", -1),
            ip_call("IP_CONNECT", 0, 80),
            ip_call("IP_CONNECT", OURS, 0),
            ip_call("IP_CONNECT", OURS, 9000),  # nobody listens
            ip_call("IP_CONNECT", OURS + 7, 9000),  # nobody answers ARP
            ip_call("IP_CONFIG", OURS, 24, 0),
            ip_call("IP_CONNECT", 8 << 24, 80),  # no way there
        )
    )
    assert said(result) == [
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_REFUSED"],
        L["E_TIMEDOUT"],
        0,
        L["E_NOROUTE"],
    ], result.console


def connect_retrying(port: int) -> str:
    """Connect to our own port, again while it is refused: the listener
    may not be listening yet. s1 = the descriptor."""
    return f"""
1:      {ip_call("IP_CONNECT", OURS, port)}
        li    t0, E_REFUSED
        beq   a0, t0, 1b
        mv    s1, a0"""


SENT = 7000  # octets: more than a buffer of three segments, so the window slides


@pytest.mark.parametrize("pause", [0, 700_000], ids=["reading", "pausing"])
def test_a_stream_longer_than_the_buffers_arrives_whole_and_in_order(pause):
    # Init connects to program 1 and sends SENT octets, octet i being
    # i mod 251, then closes; the child reads to the end and exits with
    # the sum of each octet times its position, or minus the count if
    # not all came: a lost, repeated, reordered or damaged segment
    # changes it. A child that pauses before reading lets its window
    # close for longer than the sender's timeout, so the sender probes it.
    child = f"""
        .gp   USER_GP
        {ip_call("IP_LISTEN", 9000)}
        {ip_call("IP_ACCEPT")}
        mv    s1, a0
        li    s4, {pause + 1}
5:      addi  s4, s4, -1
        bnez  s4, 5b
        li    s2, 0                    # s2: octets
        li    s3, 0                    # s3: their sum, weighted by position
1:      {io("SYS_READ", "s1", "rbuf", 700)}
        blez  a0, 3f
        la    t0, rbuf
        add   t1, t0, a0
2:      lt    t2, 0(t0)
        addi  s2, s2, 1
        mul   t2, t2, s2
        add   s3, s3, t2
        addi  t0, t0, 1
        blt   t0, t1, 2b
        j     1b
3:      mv    a1, s3
        li    t0, {SENT}
        beq   s2, t0, 4f
        sub   a1, zero, s2             # not all of it: minus what came
4:      li    a0, SYS_EXIT
        sys
{RBUF}
"""
    init = f"""
        .gp   USER_GP
        la    t0, out                  # octet i is i mod 251
        li    t1, 0
1:      li    t2, 251
        rem   t2, t1, t2
        add   t3, t0, t1
        st    t2, 0(t3)
        addi  t1, t1, 1
        li    t2, {SENT}
        blt   t1, t2, 1b
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        mv    s5, a0
        {connect_retrying(9000)}
        {io("SYS_WRITE", "s1", "out", SENT)}
        mv    s4, a0
        {close("s1")}
        li    a0, SYS_WAIT
        mv    a1, s5
        sys
        mv    a1, s4
        li    a0, SYS_EXIT
        sys
out:    .zero {SENT}
"""
    result = run(init, child, max_steps=8_000_000)
    assert result.code_of(0) == SENT, result.console
    weighted = sum((i % 251) * (i + 1) for i in range(SENT))
    assert result.code_of(3) == weighted, result.console


def test_a_listener_that_ends_resets_what_it_did_not_accept():
    # Program 1 listens and exits without accepting: the connection init
    # made to it is reset, and init's read says so.
    child = f"""
        .gp   USER_GP
        {ip_call("IP_LISTEN", 9000)}
        li    s1, 30000                # time for init to connect
1:      addi  s1, s1, -1
        bnez  s1, 1b
        li    a1, 0
        li    a0, SYS_EXIT
        sys
"""
    init = f"""
        .gp   USER_GP
        li    a0, SYS_SPAWN
        li    a1, 1
        sys
        {connect_retrying(9000)}
        {io("SYS_READ", "s1")}
        mv    a1, a0
        li    a0, SYS_EXIT
        sys
{RBUF}
"""
    result = run(init, child)
    assert result.code_of(0) == L["E_RESET"], result.console


def test_shutdown_ends_one_direction_and_leaves_the_other():
    result = run(
        report(
            ip_call("IP_LISTEN", 9000),
            ip_call("IP_CONNECT", OURS, 9000) + "\n        mv    s1, a0",
            ip_call("IP_ACCEPT") + "\n        mv    s2, a0",
            io("SYS_WRITE", "s1", "hello", 5),
            """
        li    a0, SYS_IOCALL
        mv    a1, s1
        li    a2, IO_SHUTDOWN
        sys""",
            io("SYS_WRITE", "s1", "hello", 5),  # no more writing
            io("SYS_READ", "s2"),  # what was written,
            io("SYS_READ", "s2"),  # then the end
            io("SYS_WRITE", "s2", "hello", 3),  # the other way is open
            io("SYS_READ", "s1"),
            close("s2"),
            io("SYS_READ", "s1"),  # and now ends
            close("s1"),
            data='hello: .ascii "hello"\n' + RBUF,
        )
    )
    assert said(result) == [0, 0, 1, 5, 0, L["E_PIPE"], 5, 0, 3, 3, 0, 0, 0], (
        result.console
    )


# A file of 3,000 octets: more than a segment, and more than a
# connection's buffer.
LONG = "".join(f"line {i:02} {'x' * 31}\n" for i in range(75))


def test_nc_talks_tcp_to_the_echo_service():
    result = run_image(
        assemble_file(ROOT / "shell.s"),
        input="echo hello tcp | nc 10.0.0.2 7\ncat t | nc 10.0.0.2 7 | wc\n"
        "cat t | wc\necho x | nc 10.0.0.2 9000\n"
        "echo x | nc 10.0.0.9 7\nnc 10.0.0.2\n",
        disk=bin_disk(t=LONG),
        link="loop",
        max_steps=30_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    lines = out.split("\n")
    assert lines[:2] == ["$ echo hello tcp | nc 10.0.0.2 7", "hello tcp"], out
    # The whole file comes back, as long as it went.
    assert lines[3] == lines[5] == "75 225 3000", out
    assert "\n".join(lines[6:]) == (
        "$ echo x | nc 10.0.0.2 9000\nnc: connection refused\nsh: exit 1\n"
        "$ echo x | nc 10.0.0.9 7\nnc: no answer\nsh: exit 1\n"
        "$ nc 10.0.0.2\nusage: nc [-u] HOST PORT, or nc [-u] -l PORT\n"
        "sh: exit 2\n$ \n"
    ), out


# --- names -------------------------------------------------------------------

DNSD = ROOT / "tests" / "dnsd.tc"  # a name server with a fixed table


def test_names_resolve_through_the_name_server():
    # dnsd serves on the machine's own address while the program after it
    # in the pipe resolves; dnsd ARGS feeds that program ARGS.
    result = run_image(
        assemble_file(ROOT / "shell.s"),
        input="dnsd | host example.test 10.0.0.2\n"
        "dnsd | host nx.test 10.0.0.2\n"
        "host ours.test\n"
        "ifconfig nameserver 10.0.0.2\n"
        "dnsd | host ours.test\n"
        "dnsd | ping ours.test 1\n"
        "dnsd over tcp | nc ours.test 7\n"
        "host ours.test\n"
        "host bad..name\nhost\n",
        disk=bin_disk(programs=(DNSD,)),
        link="loop",
        max_steps=60_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert re.fullmatch(
        r"\$ dnsd \| host example\.test 10\.0\.0\.2\n"
        r"example\.test has address 192\.0\.2\.7\n"
        r"example\.test has address 192\.0\.2\.8\n"
        r"\$ dnsd \| host nx\.test 10\.0\.0\.2\n"
        r"host: nx\.test: no such host\nsh: exit 1\n"
        # Nothing answers for 10.0.0.3, the name server until set, on a loop.
        r"\$ host ours\.test\n"
        r"host: ours\.test: the name server did not answer\nsh: exit 1\n"
        r"\$ ifconfig nameserver 10\.0\.0\.2\n"
        r"\$ dnsd \| host ours\.test\n"
        r"ours\.test has address 10\.0\.0\.2\n"
        r"\$ dnsd \| ping ours\.test 1\n"
        r"reply from ours\.test: seq 1, \d+\.\d{3} ms\n"
        r"\$ dnsd over tcp \| nc ours\.test 7\n"
        r"over tcp\n"
        # With no name server running, the questions go unanswered.
        r"\$ host ours\.test\n"
        r"host: ours\.test: the name server did not answer\nsh: exit 1\n"
        r"\$ host bad\.\.name\nhost: bad\.\.name: not a host name\nsh: exit 1\n"
        r"\$ host\nusage: host NAME \[SERVER\]\nsh: exit 2\n"
        r"\$ \n",
        out,
    ), out


def test_the_name_server_setting_is_kept_and_checked():
    result = run(
        report(
            ip_call("IP_NAMESERVER", "NS_KEEP"),
            ip_call("IP_NAMESERVER", 0),
            ip_call("IP_NAMESERVER", 5),
            ip_call("IP_NAMESERVER", "NS_KEEP"),
            ip_call("IP_NAMESERVER", 1 << 32),
            ip_call("IP_NAMESERVER", "NS_KEEP"),
        )
    )
    assert said(result) == [(10 << 24) + 3, (10 << 24) + 3, 0, 5, -10, 5], (
        result.console
    )
