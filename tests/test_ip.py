"""The IP server (user/ipd.s): ARP and ICMP echo over IPv4, above the
network server. On a loopback link every frame it sends comes back to
it, so pinging its own address runs the whole exchange: an ARP request
and its reply, an echo request and its reply, each sent and taken in."""

import re

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tests.kernel import run as run_kernel
from tests.test_files import L, report, said

OURS = (10 << 24) + 2  # 10.0.0.2, the server's address until told otherwise
WAIT = 100_000  # rounds a ping may take: each frame waits up to 1,000 for the link


def run(*args, link="loop", **kwargs):
    """A run with the network and IP servers, processes 1 and 2."""
    return run_kernel(*args, ip=True, link=link, **kwargs)


def ip_call(op: str, *words: int | str) -> str:
    regs = "".join(f"\n        li    a{3 + i}, {w}" for i, w in enumerate(words))
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
        r"reply from 10\.0\.0\.2: seq 1, \d+ ticks\n"
        r"reply from 10\.0\.0\.2: seq 2, \d+ ticks\n"
        r"\$ ping 10\.0\.0\.9 1\n"
        r"no reply from 10\.0\.0\.9: seq 1\n"
        r"sh: exit 1\n"
        r"\$ ping 10\.0\.0\n"
        r"usage: ping ADDRESS \[COUNT\]\n"
        r"sh: exit 2\n"
        r"\$ ping 10\.0\.0\.2 x\n"
        r"usage: ping ADDRESS \[COUNT\]\n"
        r"sh: exit 2\n"
        r"\$ \n",
        out,
    ), out


def test_ifconfig_says_and_sets_the_address():
    result = run_image(
        assemble_file(ROOT / "shell.s"),
        input="ifconfig\nifconfig 192.168.1.7/16\nifconfig\n"
        "ifconfig 192.168.1.7/16 0.0.0.0\nifconfig\nping 192.168.1.7 1\n"
        "ifconfig 10.0.0.3/33\nifconfig 0.0.0.0/8\n",
        disk=bin_disk(),
        link="loop",
        max_steps=10_000_000,
    )
    assert result.exit_code == 0, result.console
    out = re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)
    assert re.fullmatch(
        r"\$ ifconfig\ninet 10\.0\.0\.2/24 gateway 10\.0\.0\.1\n"
        r"\$ ifconfig 192\.168\.1\.7/16\n"
        r"\$ ifconfig\ninet 192\.168\.1\.7/16 gateway 10\.0\.0\.1\n"
        r"\$ ifconfig 192\.168\.1\.7/16 0\.0\.0\.0\n"
        r"\$ ifconfig\ninet 192\.168\.1\.7/16 gateway none\n"
        r"\$ ping 192\.168\.1\.7 1\nreply from 192\.168\.1\.7: seq 1, \d+ ticks\n"
        r"\$ ifconfig 10\.0\.0\.3/33\nusage: ifconfig \[ADDRESS/PREFIX \[GATEWAY\]\]\n"
        r"sh: exit 2\n"
        r"\$ ifconfig 0\.0\.0\.0/8\nifconfig: the IP server refused\nsh: exit 1\n"
        r"\$ \n",
        out,
    ), out
