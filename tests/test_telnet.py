"""bin/telnetd gives a TCP connection a shell, and bin/telnet reaches
it: both on one machine, over a loop link, telnetd started by
/etc/init."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str, etc_init: str | None = None) -> str:
    """What the shell said to typed, the kernel's messages left out."""
    result = run_image(
        shell,
        input=typed,
        disk=bin_disk(etc_init=etc_init),
        link="loop",
        ram_pages=729,  # Rust programs beside the shell's
        max_steps=400_000_000,
    )
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


TELNETD = "pipe\nnet\nip\n/bin/telnetd -n 1\n"


def test_telnet_reaches_a_remote_shell(shell):
    out = session(shell, "echo 'echo hi | upper' | telnet 10.0.0.2\nps\n", TELNETD)
    assert out.startswith(
        "$ echo 'echo hi | upper' | telnet 10.0.0.2\n"
        # The remote shell echoes what it reads, prompts, and says hi.
        "$ echo hi | upper\nHI\n$ \n"
        "$ ps\n"
    ), out


def test_telnet_talks_to_any_tcp_service(shell):
    # The echo service on port 7 speaks no Telnet: line mode.
    out = session(shell, "echo hello | telnet 10.0.0.2 7\ntelnet 10.0.0.2 9\ntelnet\n")
    assert out == (
        "$ echo hello | telnet 10.0.0.2 7\nhello\n"
        "$ telnet 10.0.0.2 9\ntelnet: 10.0.0.2:9: connection refused\nsh: exit 1\n"
        "$ telnet\nusage: telnet HOST [PORT]\nsh: exit 2\n"
        "$ \n"
    )


def test_telnetd_says_how_to_use_it(shell):
    out = session(shell, "telnetd -x\ntelnetd -p\n")
    assert out == (
        "$ telnetd -x\nusage: telnetd [-p PORT] [-n COUNT]\nsh: exit 2\n"
        "$ telnetd -p\nusage: telnetd [-p PORT] [-n COUNT]\nsh: exit 2\n"
        "$ \n"
    )
