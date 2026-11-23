"""init (user/init.s): program 0 of shell.s, which starts the servers in
order and then the shell."""

from tests.kernel import ROOT, _assemble, assemble_file, bin_disk, run_image


def trouble(console: str) -> list[str]:
    """init's lines other than those it says as each server and the shell
    start (tests/test_boot.py)."""
    return [
        line
        for line in console.splitlines()
        if line.startswith("init:")
        and not line.startswith(("init: started ", "init: starting sh"))
    ]


def shell_build(**numbers: int):
    """shell.s with some of the program numbers init starts changed."""
    source = (ROOT / "shell.s").read_text()
    for name, number in numbers.items():
        line = next(s for s in source.splitlines() if f".equ  {name}," in s)
        source = source.replace(line, f"        .equ  {name}, {number}")
    return _assemble(["-"], stdin=source)


def test_init_starts_the_servers_before_the_shell_and_ends_after_it():
    result = run_image(
        assemble_file(ROOT / "shell.s"), input="ls\nexit\n", disk=bin_disk()
    )
    assert result.exit_code == 0, result.console
    # Every server is up by the shell's first prompt, so ls works at once.
    assert "$ ls\nbin/\n$ exit\n" in result.console
    lines = result.console.splitlines()
    assert lines[-3:-1] == [
        "trylobite: process 5 exited with code 0",  # the shell,
        "trylobite: process 0 exited with code 0",  # then init
    ]
    # Only the boot lines (tests/test_boot.py): nothing went wrong.
    said = [line for line in lines if line.startswith("init:")]
    assert said == [
        "init: started console, process 1",
        "init: started pipe, process 2",
        "init: started disk, process 3",
        "init: started fs, process 4",
        "init: starting sh",
    ]


def test_a_server_that_cannot_start_takes_what_needs_it_down():
    # No program 27: the disk server cannot start, so neither does the file
    # server, which needs it; the shell runs without files.
    result = run_image(shell_build(INIT_DISKD=27), input="ls\nhello\n", disk=bin_disk())
    assert result.exit_code == 0, result.console
    console = result.console
    assert (
        "init: no server named disk\ninit: no server named fs\ninit: starting sh\n$ "
        in console
    )
    assert "$ ls\nsh: .: no filesystem on the disk\n" in console
    assert "$ hello\nsh: no such program: hello\n" in console


def test_a_server_init_does_not_need_can_be_missing():
    # Without the pipe server the rest still starts.
    result = run_image(shell_build(INIT_PIPED=27), input="ls\n", disk=bin_disk())
    assert trouble(result.console) == ["init: no server named pipe"]
    assert "init: started fs, process 3\n" in result.console
    assert "$ ls\nbin/\n" in result.console
    assert "init: no server named fs" not in result.console


def build_with(numbers: dict[str, int], *programs: str):
    """shell.s with some of init's program numbers changed, and more
    programs, numbered 9 on."""
    source = (ROOT / "shell.s").read_text()
    for name, number in numbers.items():
        line = next(s for s in source.splitlines() if f".equ  {name}," in s)
        source = source.replace(line, f"        .equ  {name}, {number}")
    source = source.replace(".equ  NPROG, 9", f".equ  NPROG, {9 + len(programs)}")
    for number, body in enumerate(programs, 9):
        source += f"""
        .section prog{number}, (P_PROG0 + {number}) * PAGE, V_USER
        .gp   USER_GP
{body}
"""
    return _assemble(["-"], stdin=source)


def failing_server(name: str, protocol: str) -> str:
    """A server that registers `name` and ends at the first call to it."""
    return f"""
        li    a0, SYS_REGISTER
        la    a1, 3f
        li    a2, {protocol}
        sys
1:      li    a0, SYS_RECEIVE
        sys
        bltz  a0, 1b                   # a notice: keep waiting
        li    a0, SYS_EXIT
        li    a1, 9
        sys
3:      .string "{name}"
"""


def calling_shell(name: str) -> str:
    """A shell that calls server `name` once and then waits to be ended;
    it exits, and init with it, once there is no such server."""
    return f"""
        li    a0, SYS_LOOKUP
        la    a1, 3f
        li    a2, LOOKUP_NOW
        sys
        bltz  a0, 2f
        mv    a1, a0
        li    a0, SYS_CALL
        li    a2, 0
        sys                            # the server ends rather than answer
1:      li    a0, SYS_RECV
        sys
        j     1b
2:      li    a0, SYS_EXIT
        li    a1, 0
        sys
3:      .string "{name}"
"""


def test_a_server_that_ends_is_started_again_until_init_gives_up():
    # The pipe server ends at each call: init starts it again, and the
    # shell, which needs it, three times, then gives up on it; the shell
    # then finds no pipe server and exits, and init with it.
    image = build_with(
        {"INIT_PIPED": 9, "INIT_SH": 10},
        failing_server("pipe", "PIPE_PROTOCOL"),
        calling_shell("pipe"),
    )
    result = run_image(image, max_steps=10_000_000)
    assert result.exit_code == 0, result.console
    assert trouble(result.console) == ["init: pipe ended, starting it again"] * 3 + [
        "init: pipe ended too often, giving up on it"
    ]
    assert result.console.count(" killed\n") == 4  # the shell, each time
    assert result.code_of(0) == 0


def test_what_needs_a_server_that_ends_is_started_again_with_it():
    # The disk server ends at its first call: the file server (process 4),
    # which needs it, and the shell (5) are ended and started again too.
    image = build_with(
        {"INIT_DISKD": 9, "INIT_SH": 10},
        failing_server("disk", "DISK_PROTOCOL"),
        calling_shell("disk"),
    )
    result = run_image(image, disk=bin_disk(), max_steps=10_000_000)
    assert result.exit_code == 0, result.console
    console = result.console
    assert console.count("init: disk ended, starting it again\n") == 3
    assert "trylobite: process 4 killed\n" in console  # the file server
    assert "trylobite: process 5 killed\n" in console  # the shell
    # Given up on the disk server, init leaves the file server down too.
    assert trouble(console)[-2:] == [
        "init: disk ended too often, giving up on it",
        "init: no server named fs",
    ]


def test_a_server_that_ends_before_it_registers_is_started_again():
    # The disk server exits before it registers: init does not wait for
    # the name forever but starts it again, three times, then gives up on
    # it and on the file server, which needs it, and starts the shell.
    image = build_with(
        {"INIT_DISKD": 9},
        "li    a0, SYS_EXIT\n        li    a1, 3\n        sys",
    )
    result = run_image(image, input="ls\n", disk=bin_disk())
    assert result.exit_code == 0, result.console
    console = result.console
    assert "deadlock" not in console
    assert console.count(" exited with code 3\n") == 4  # the first start and
    # three more
    assert trouble(console) == ["init: disk ended, starting it again"] * 3 + [
        "init: disk ended too often, giving up on it",
        "init: no server named fs",
    ]
    assert "$ ls\nsh: .: no filesystem on the disk\n" in console


def test_a_server_that_ends_once_before_it_registers_comes_up():
    # The pipe server's first start (process 2) exits before it registers;
    # the second, process 3, registers, and the rest comes up after it.
    image = build_with(
        {"INIT_PIPED": 9},
        """
        li    a0, SYS_GETPID
        sys
        li    t0, 2
        bne   a0, t0, 1f
        li    a0, SYS_EXIT
        li    a1, 3
        sys
1:      li    a0, SYS_REGISTER
        la    a1, 3f
        li    a2, PIPE_PROTOCOL
        sys
2:      li    a0, SYS_RECEIVE
        sys
        j     2b
3:      .string "pipe"
""",
    )
    result = run_image(image, input="ls\n", disk=bin_disk())
    assert result.exit_code == 0, result.console
    said = [line for line in result.console.splitlines() if line.startswith("init:")]
    assert said == [
        "init: started console, process 1",
        "init: pipe ended, starting it again",
        "init: started pipe, process 3",
        "init: started disk, process 4",
        "init: started fs, process 5",
        "init: starting sh",
    ]
    assert "$ ls\nbin/\n" in result.console


def test_a_shell_that_faults_is_started_again_until_init_gives_up():
    image = build_with({"INIT_SH": 9}, "lw    t0, 0(zero)  # nothing is there")
    result = run_image(image, disk=bin_disk())
    console = result.console
    assert console.count(" faulted") == 4  # the first start and three more
    assert console.count("init: sh ended, starting it again\n") == 3
    assert "init: sh ended too often, giving up on it\n" in console
    assert result.code_of(0) == 1  # INIT_LOST
