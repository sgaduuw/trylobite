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
        "trylobite: process 7 exited with code 0",  # the shell,
        "trylobite: process 0 exited with code 0",  # then init
    ]
    # Only the boot lines (tests/test_boot.py): nothing went wrong.
    said = [line for line in lines if line.startswith("init:")]
    assert said == [
        "init: started console, process 1",
        "init: started disk, process 2",
        "init: started fs, process 3",
        "init: started pipe, process 4",
        "init: started net, process 5",
        "init: started ip, process 6",
        "init: starting sh",
    ]


def test_a_server_that_cannot_start_takes_what_needs_it_down():
    # No program 27: the disk server cannot start, so neither does the file
    # server, which needs it, nor the shell, which is a file: init gives up.
    result = run_image(shell_build(INIT_DISKD=27), input="ls\nhello\n", disk=bin_disk())
    assert result.exit_code == 0, result.console
    assert (
        "init: no server named disk\ninit: no server named fs\n"
        "init: started pipe, process 2\n"
        "init: started net, process 3\ninit: started ip, process 4\n"
        "init: starting sh\ninit: cannot start /bin/sh\n"
        "trylobite: process 0 exited with code 1\n" in result.console
    )


def test_a_server_init_does_not_need_can_be_missing():
    # Without the pipe server the rest still starts.
    result = run_image(shell_build(INIT_PIPED=27), input="ls\n", disk=bin_disk())
    assert trouble(result.console) == ["init: no server named pipe"]
    assert "init: started fs, process 3\n" in result.console
    assert "$ ls\nbin/\n" in result.console
    assert "init: no server named fs" not in result.console


def build_with(numbers: dict[str, int], *programs: str):
    """shell.s with some of init's program numbers changed, and more
    programs, numbered 10 on."""
    source = (ROOT / "shell.s").read_text()
    for name, number in numbers.items():
        line = next(s for s in source.splitlines() if f".equ  {name}," in s)
        source = source.replace(line, f"        .equ  {name}, {number}")
    source = source.replace(".equ  NPROG, 10", f".equ  NPROG, {10 + len(programs)}")
    for number, body in enumerate(programs, 10):
        source += f"""
        .section prog{number}, (P_PROG0 + {number} + FS_PAGES - 1) * PAGE, V_USER
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
        {"INIT_PIPED": 10, "INIT_SH": 11},
        failing_server("pipe", "PIPE_PROTOCOL"),
        calling_shell("pipe"),
    )
    result = run_image(image, max_steps=25_000_000)
    assert result.exit_code == 0, result.console
    assert trouble(result.console) == ["init: pipe ended, starting it again"] * 3 + [
        "init: pipe ended too often, giving up on it"
    ]
    assert result.console.count(" killed\n") == 4  # the shell, each time
    assert result.code_of(0) == 0


def test_what_needs_a_server_that_ends_is_started_again_with_it():
    # The disk server ends at its first call: the file server (process 3),
    # which needs it, and the shell are ended and started again too.
    image = build_with(
        {"INIT_DISKD": 10, "INIT_SH": 11},
        failing_server("disk", "DISK_PROTOCOL"),
        calling_shell("disk"),
    )
    result = run_image(image, disk=bin_disk(), max_steps=25_000_000)
    assert result.exit_code == 0, result.console
    console = result.console
    assert console.count("init: disk ended, starting it again\n") == 3
    assert "trylobite: process 3 killed\n" in console  # the file server
    # The shell, each time: the first start, three more, and one without it.
    assert console.count("init: starting sh\n") == 5
    # Given up on the disk server, init leaves the file server down too.
    assert trouble(console)[-2:] == [
        "init: disk ended too often, giving up on it",
        "init: no server named fs",
    ]


def test_a_server_that_ends_before_it_registers_is_started_again():
    # The disk server exits before it registers: init does not wait for
    # the name forever but starts it again, three times, then gives up on
    # it and on the file server, which needs it; with no file server
    # there is no /bin/sh to start, so init gives up (INIT_LOST).
    image = build_with(
        {"INIT_DISKD": 10},
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
        "init: cannot start /bin/sh",
    ]
    assert result.code_of(0) == 1


def test_a_server_that_ends_once_before_it_registers_comes_up():
    # The pipe server's first start (process 4) exits before it registers;
    # the second, process 5, registers, and the rest comes up after it.
    image = build_with(
        {"INIT_PIPED": 10},
        """
        li    a0, SYS_GETPID
        sys
        li    t0, 4
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
        "init: started disk, process 2",
        "init: started fs, process 3",
        "init: pipe ended, starting it again",
        "init: started pipe, process 5",
        "init: started net, process 6",
        "init: started ip, process 7",
        "init: starting sh",
    ]
    assert "$ ls\nbin/\n" in result.console


def test_a_shell_that_faults_is_started_again_until_init_gives_up():
    image = build_with({"INIT_SH": 10}, "lw    t0, 0(zero)  # nothing is there")
    result = run_image(image, disk=bin_disk())
    console = result.console
    assert console.count(" faulted") == 4  # the first start and three more
    assert console.count("init: sh ended, starting it again\n") == 3
    assert "init: sh ended too often, giving up on it\n" in console
    assert result.code_of(0) == 1  # INIT_LOST


def boot(etc_init: str, input: str = "exit\n", **kwargs):
    """shell.s on a disk whose /etc/init is etc_init."""
    disk = bin_disk(etc_init=etc_init, **kwargs)
    return run_image(assemble_file(ROOT / "shell.s"), input=input, disk=disk)


def said(console: str) -> list[str]:
    return [line for line in console.splitlines() if line.startswith("init:")]


def test_etc_init_says_which_servers_start_after_the_bootstrap_ones():
    # Comments, empty lines and spaces say nothing. Without net and ip the
    # shell is process 5.
    result = boot("# just pipes\n\n   pipe  \n", input="ls\nexit\n")
    assert result.exit_code == 0, result.console
    assert said(result.console) == [
        "init: started console, process 1",
        "init: started disk, process 2",
        "init: started fs, process 3",
        "init: started pipe, process 4",
        "init: starting sh",
    ]
    assert "$ ls\nbin/\netc/\n" in result.console
    assert "trylobite: process 5 exited with code 0" in result.console


def test_a_server_in_etc_init_brings_what_it_needs():
    # ip needs net; init's order holds, whatever the file's.
    result = boot("ip\npipe\n")
    assert said(result.console)[3:] == [
        "init: started pipe, process 4",
        "init: started net, process 5",
        "init: started ip, process 6",
        "init: starting sh",
    ]


def test_an_empty_etc_init_starts_only_the_bootstrap_servers():
    result = boot("")
    assert result.exit_code == 0, result.console
    assert said(result.console)[3:] == ["init: starting sh"]


def test_etc_init_names_no_such_server():
    result = boot("pipe\nwhatever\n")
    assert trouble(result.console) == ["init: /etc/init: no server named whatever"]
    assert "init: started pipe, process 4" in result.console


def test_a_program_in_etc_init_starts_with_its_arguments_before_the_shell():
    # Once it has exited it is done, not started again. (Its words are
    # split at spaces, however many.) The shell sleeps until touch is
    # surely done, which on one hart can take a few slices.
    result = boot(
        "/bin/touch   /from-init  /made-by-init\n", input="sleep 2000000\nls\n"
    )
    assert result.exit_code == 0, result.console
    console = result.console
    assert said(console) == [
        "init: started console, process 1",
        "init: started disk, process 2",
        "init: started fs, process 3",
        "init: started /bin/touch, process 4",
        "init: starting sh",
    ]
    assert "trylobite: process 4 exited with code 0" in console
    listed = console.partition("$ ls\n")[2].splitlines()
    assert "0 from-init" in listed and "0 made-by-init" in listed  # empty


def test_a_program_in_etc_init_that_faults_is_started_again_until_init_gives_up():
    # The shell sleeps so as not to exit, and end init, before then.
    result = boot(
        "/bin/crash\n", "sleep 3000000\nexit\n", programs=(ROOT / "tests" / "crash.s",)
    )
    assert result.exit_code == 0, result.console
    console = result.console
    assert console.count(" faulted") == 4  # the first start and three more
    # Counted, not listed: what the shell echoes may land inside a line.
    assert console.count("init: /bin/crash ended, starting it again\n") == 3
    assert console.count("init: /bin/crash ended too often, giving up on it\n") == 1


def test_a_program_in_etc_init_that_cannot_start_is_said():
    result = boot("/bin/nothing\npipe\n", input="ls\n")
    assert trouble(result.console) == ["init: cannot start /bin/nothing"]
    assert "$ ls\nbin/\netc/\n" in result.console


def test_init_ends_the_programs_when_the_shell_exits():
    # spin never ends by itself: init ends it, so the machine powers off.
    result = boot("/bin/spin\n")
    assert result.exit_code == 0, result.console
    lines = result.console.splitlines()
    assert "init: started /bin/spin, process 4" in lines
    assert lines[-4:-1] == [
        "trylobite: process 5 exited with code 0",  # the shell,
        "trylobite: process 4 killed",  # spin,
        "trylobite: process 0 exited with code 0",  # then init
    ]


def test_programs_start_again_with_a_server_that_ends():
    # Killing the file server from the shell ends spin too, and both start
    # again.
    result = boot("/bin/spin\n", input="kill 3\nexit\n")
    console = result.console
    assert "init: fs ended, starting it again" in console
    assert console.count("init: started /bin/spin, process ") == 2


def test_a_long_etc_init_is_read_as_far_as_init_can():
    result = boot("pipe\n" + "#" * 800 + "\nnet\n")
    assert trouble(result.console) == [
        "init: /etc/init: too long, reading the start of it"
    ]
    assert "init: started pipe, process 4" in result.console
    assert "init: started net" not in result.console
