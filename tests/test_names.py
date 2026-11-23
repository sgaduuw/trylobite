"""Server names (kernel/names.s): register, lookup, waiting for a name,
and names going with their server."""

from tests.kernel import EXIT, run
from tests.test_files import L, report, said
from tests.test_files import run as run_files


def register(name: str, version: int | str) -> str:
    load = "la" if name.isidentifier() else "li"  # a label, or an address
    return f"""
        li    a0, SYS_REGISTER
        {load}    a1, {name}
        li    a2, {version}
        sys"""


def lookup(name: str, how: str = "LOOKUP_NOW", pid: str = "zero") -> str:
    return f"""
        li    a0, SYS_LOOKUP
        la    a1, {name}
        li    a2, {how}
        mv    a3, {pid}
        sys"""


VERSION = "        mv    a0, a1"  # print what lookup left in a1


def strings(**texts: str) -> str:
    return "".join(f'{label}: .string "{text}"\n' for label, text in texts.items())


def test_a_registered_name_is_found_with_its_version():
    program = report(
        register("abc", 3),
        lookup("abc"),
        lookup("abc") + "\n" + VERSION,
        lookup("ab"),  # names match whole: neither a prefix
        lookup("abcd"),  # nor a longer name
        register("abc", 4),  # its own name again: a new version
        lookup("abc") + "\n" + VERSION,
        register("eight", 1),
        lookup("eight"),
        data=strings(abc="abc", ab="ab", abcd="abcd", eight="abcdefgh"),
    )
    assert said(run(program)) == [0, 0, 3, L["E_NOENT"], L["E_NOENT"], 0, 4, 0, 0]


def test_what_cannot_be_registered_says_why():
    program = report(
        register("abc", 0),
        register("abc", -1),
        register("empty", 1),
        register("nine", 1),
        register("0", 1),  # not the caller's memory
        lookup("empty"),
        lookup("nine"),
        data=strings(abc="abc", empty="", nine="abcdefghi"),
    )
    assert said(run(program)) == [
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_INVAL"],
        L["E_NAMETOOLONG"],
        L["E_FAULT"],
        L["E_INVAL"],
        L["E_NAMETOOLONG"],
    ]


def test_the_kernel_keeps_nsrv_names():
    n = L["NSRV"]
    labels = {f"n{i}": f"name{i}" for i in range(n + 1)}
    program = report(*(register(label, 1) for label in labels), data=strings(**labels))
    assert said(run(program)) == [0] * n + [L["E_NOSPC"]]


# A server that lets init run first, so that init's lookup waits for it,
# registers "srv" with version 7, and then waits for a message forever.
SERVER = """
        .gp   USER_GP
        li    s1, 20
1:      li    a0, SYS_YIELD
        sys
        addi  s1, s1, -1
        bnez  s1, 1b
        li    a0, SYS_REGISTER
        la    a1, srv_name
        li    a2, 7
        sys
        li    a0, SYS_RECV
        sys
srv_name: .string "srv"
"""


def test_a_lookup_waits_for_the_name_and_the_name_goes_with_its_server():
    init = report(
        "li a0, SYS_SPAWN\n        li a1, 1\n        sys\n        mv s1, a0",
        lookup("srv", "LOOKUP_WAIT"),
        lookup("srv") + "\n" + VERSION,
        register("srv", 1),  # somebody else's
        "li a0, SYS_KILL\n        mv a1, s1\n        li a2, FOR_SELF\n        sys",
        "li a0, SYS_WAIT\n        mv a1, s1\n        sys",
        lookup("srv"),  # gone with it
        register("srv", 1),  # and free again
        data=strings(srv="srv"),
    )
    assert said(run(init, SERVER)) == [
        1,
        1,
        7,
        L["E_EXIST"],
        0,
        L["WAIT_KILLED"],
        L["E_NOENT"],
        0,
    ]


def test_waiting_for_a_name_nobody_will_register_is_a_deadlock():
    program = report(lookup("none", "LOOKUP_WAIT"), data=strings(none="none"))
    result = run(program)
    assert result.exit_code == 1
    assert "deadlock" in result.console


def test_a_process_waiting_for_a_name_can_be_killed():
    child = f"""
        .gp   USER_GP
        {lookup("none", "LOOKUP_WAIT")}
        mv    a1, a0
        {EXIT}
none:   .string "none"
"""
    init = report(
        "li a0, SYS_SPAWN\n        li a1, 1\n        sys\n        mv s1, a0",
        "li a0, SYS_YIELD\n        sys",
        "li a0, SYS_KILL\n        mv a1, s1\n        li a2, FOR_SELF\n        sys",
        "li a0, SYS_WAIT\n        mv a1, s1\n        sys",
    )
    assert said(run(init, child)) == [1, 0, 0, L["WAIT_KILLED"]]


def test_a_second_file_server_finds_the_name_taken_and_leaves():
    # The harness starts the disk server and the file server, program 4,
    # first; this starts another file server and reads how it ended.
    program = report(
        "li a0, SYS_SPAWN\n        li a1, 4\n        sys\n        mv s1, a0",
        "li a0, SYS_WAIT\n        mv a1, s1\n        sys\n        mv s2, a1",
        "mv a0, s2",
    )
    assert said(run_files(program)) == [3, L["WAIT_EXITED"], L["E_EXIST"]]


# A child that lets its parent's lookup start waiting, then exits without
# registering anything.
QUITTER = """
        .gp   USER_GP
        li    s1, 20
1:      li    a0, SYS_YIELD
        sys
        addi  s1, s1, -1
        bnez  s1, 1b
        li    a0, SYS_EXIT
        li    a1, 0
        sys
"""


def test_a_lookup_while_a_process_lives_ends_with_it():
    # The child ends without registering: the wait ends with E_NOPROC, and
    # the child is still there to wait for.
    init = report(
        "li a0, SYS_SPAWN\n        li a1, 1\n        sys\n        mv s1, a0",
        lookup("srv", "LOOKUP_WHILE", "s1"),
        "li a0, SYS_WAIT\n        mv a1, s1\n        sys",
        lookup("srv", "LOOKUP_WHILE", "s1"),  # ended already
        data=strings(srv="srv"),
    )
    assert said(run(init, QUITTER)) == [
        1,
        L["E_NOPROC"],
        L["WAIT_EXITED"],
        L["E_NOPROC"],
    ]


def test_a_lookup_while_a_process_lives_finds_its_name():
    init = report(
        "li a0, SYS_SPAWN\n        li a1, 1\n        sys\n        mv s1, a0",
        lookup("srv", "LOOKUP_WHILE", "s1") + "\n" + VERSION,
        data=strings(srv="srv"),
    )
    assert said(run(init, SERVER)) == [1, 7]


def test_a_lookup_while_no_process_lives_fails_at_once():
    init = report(
        "li s1, 13" + lookup("srv", "LOOKUP_WHILE", "s1"),  # never started
        "li s1, -1" + lookup("srv", "LOOKUP_WHILE", "s1"),
        "li s1, NPROC" + lookup("srv", "LOOKUP_WHILE", "s1"),
        data=strings(srv="srv"),
    )
    assert said(run(init)) == [L["E_NOPROC"]] * 3
