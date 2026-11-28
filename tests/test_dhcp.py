"""bin/dhcp takes the machine's address from a DHCP server, through the
IP server's broadcasts. tests/dhcpsd.rs is the server, on the machine
itself over a loop link, so that runs repeat exactly; detrytus' own
server (--net user) answers the same way on a live machine."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image

DHCPSD = ROOT / "tests" / "dhcpsd.rs"


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str, etc_init: str | None = None) -> str:
    """What the shell said to typed, the kernel's messages left out."""
    result = run_image(
        shell,
        input=typed,
        disk=bin_disk(programs=(DHCPSD,), etc_init=etc_init),
        link="loop",
        ram_pages=729,  # Rust programs beside the shell's
        max_steps=300_000_000,
    )
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_dhcp_sets_the_address_the_server_gives(shell):
    out = session(
        shell,
        "dhcpsd 10.0.0.42 | dhcp -n\n"
        "ifconfig\n"
        "dhcpsd 10.0.0.42 | dhcp\n"
        "ifconfig\n"
        "dhcpsd 10.0.0.42 nak | dhcp\n"
        "dhcp\n"
        "dhcp -x\n",
    )
    assert out == (
        "$ dhcpsd 10.0.0.42 | dhcp -n\n"
        "inet 10.0.0.42/24 gateway 10.0.0.1 nameserver 10.0.0.9 lease 7200 s\n"
        # -n sets nothing.
        "$ ifconfig\ninet 10.0.0.2/24 gateway 10.0.0.1 nameserver 10.0.0.3\n"
        "$ dhcpsd 10.0.0.42 | dhcp\n"
        "inet 10.0.0.42/24 gateway 10.0.0.1 nameserver 10.0.0.9 lease 7200 s\n"
        "$ ifconfig\ninet 10.0.0.42/24 gateway 10.0.0.1 nameserver 10.0.0.9\n"
        "$ dhcpsd 10.0.0.42 nak | dhcp\n"
        "dhcp: the DHCP server refused\nsh: exit 1\n"
        "$ dhcp\ndhcp: no DHCP server answered\nsh: exit 1\n"
        "$ dhcp -x\nusage: dhcp [-d] [-n]\nsh: exit 2\n"
        "$ \n"
    )


def test_dhcp_from_etc_init_keeps_the_lease(shell):
    etc_init = "pipe\nnet\nip\n/bin/dhcpsd 10.0.0.42\n/bin/dhcp -d\n"
    out = session(shell, "sleep 3000000\nifconfig\nps\n", etc_init)
    assert (
        "dhcp: inet 10.0.0.42/24 gateway 10.0.0.1 nameserver 10.0.0.9 lease 7200 s\n"
        in out
    )
    assert "$ ifconfig\ninet 10.0.0.42/24 gateway 10.0.0.1 nameserver 10.0.0.9\n" in out
    assert re.search(r"\d+ +\S+ +dhcp\n", out), out
