"""init (user/init.s): program 0 of shell.s, which starts the servers in
order and then the shell."""

from tests.kernel import ROOT, _assemble, assemble_file, bin_disk, run_image


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
    assert not any(line.startswith("init:") for line in lines)  # quiet


def test_a_server_that_cannot_start_takes_what_needs_it_down():
    # No program 27: the disk server cannot start, so neither does the file
    # server, which needs it; the shell runs without files.
    result = run_image(shell_build(INIT_DISKD=27), input="ls\nhello\n", disk=bin_disk())
    assert result.exit_code == 0, result.console
    console = result.console
    assert "init: no server named disk\ninit: no server named fs\n$ " in console
    assert "$ ls\nsh: .: no filesystem on the disk\n" in console
    assert "$ hello\nsh: no such program: hello\n" in console


def test_a_server_init_does_not_need_can_be_missing():
    # Without the pipe server the rest still starts.
    result = run_image(shell_build(INIT_PIPED=27), input="ls\n", disk=bin_disk())
    assert "init: no server named pipe\n$ ls\nbin/\n" in result.console
    assert "init: no server named fs" not in result.console
