"""Scripting in the shell: lists (; && ||), if, while, until, for, case,
functions, test and [, read, $((...)), $(...), patterns, background
jobs, and scripts run as `sh FILE`, `sh -c`, `.` or by their #! line."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, disk=None, max_steps=60_000_000) -> str:
    """What the shell said to typed, the kernel's messages left out."""
    result = run_image(shell, input=typed, disk=disk or bin_disk(), max_steps=max_steps)
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def outputs(shell, typed: str, disk=None) -> list[str]:
    """What each command printed, the prompts and echoed lines left out."""
    out = said(shell, typed, disk)
    lines = []
    for line in out.splitlines():
        if line.startswith("$ ") or line.startswith("> ") or line in ("$", ">"):
            continue
        lines.append(line)
    return lines


def test_lists_run_in_turn_and_on_status(shell):
    typed = (
        "echo a; echo b\n"
        "true && echo yes || echo no\n"
        "false && echo yes || echo no\n"
        "false || false || echo third\n"
        "! false && echo negated\n"
    )
    assert outputs(shell, typed) == ["a", "b", "yes", "no", "third", "negated"]


def test_if_elif_else(shell):
    typed = (
        "for n in 1 2 3; do\n"
        "if [ $n -eq 1 ]; then echo one; elif [ $n = 2 ]; then echo two\n"
        "else echo many; fi\n"
        "done\n"
    )
    assert outputs(shell, typed) == ["one", "two", "many"]


def test_while_until_break_and_continue(shell):
    typed = (
        "i=0; while [ $i -lt 5 ]; do i=$((i + 1)); "
        "if [ $i = 2 ]; then continue; fi; if [ $i = 4 ]; then break; fi; "
        "echo i$i; done\n"
        "until [ $i -le 0 ]; do i=$((i - 2)); echo u$i; done\n"
        "for a in 1 2; do for b in x y; do "
        "if [ $b = y ]; then continue 2; fi; echo $a$b; done; done\n"
    )
    assert outputs(shell, typed) == ["i1", "i3", "u2", "u0", "1x", "2x"]


def test_case_patterns(shell):
    typed = (
        "for w in apple b42 '*' zz; do case $w in\n"
        "a*) echo fruit;;\n"
        "b[0-9]*|c) echo code;;\n"
        "'*') echo star;;\n"
        "*) echo other $w\n"
        "esac; done\n"
    )
    assert outputs(shell, typed) == ["fruit", "code", "star", "other zz"]


def test_functions_parameters_and_return(shell):
    typed = (
        'greet() { echo "hi $1 ($#: $@)"; return 3; }\n'
        "greet bob 'ann lee'; echo $?\n"
        'each() { for a in "$@"; do echo "[$a]"; done; }\n'
        "each 'a b' c\n"
        "fact() { if [ $1 -le 1 ]; then echo 1; "
        "else echo $(( $1 * $(fact $(( $1 - 1 ))) )); fi; }\n"
        "fact 5\n"
        "deep() { deep; }\ndeep\necho $?\n"
    )
    assert outputs(shell, typed) == [
        "hi bob (2: bob ann lee)",
        "3",
        "[a b]",
        "[c]",
        "120",
        "sh: functions call each other too deep",
        "1",
    ]


def test_arithmetic(shell):
    typed = (
        "x=7\n"
        "echo $((x * 2 + 1)) $(( (x + 1) / 3 )) $((x % 4)) $((-x)) $((x > 5))\n"
        "echo $((y = x << 2)) $y $((1 && 0 || 1)) $((x == 7 ? 1 : 0))\n"
        "echo $((5 / 0))\n"
    )
    assert outputs(shell, typed) == [
        "15 2 3 -7 1",
        "sh: $((x == 7 ? 1 : 0)): not a sum",
        "28 28 1 0",
        "sh: $((5 / 0)): division by 0",
        "0",
    ]


def test_command_substitution(shell):
    typed = (
        "here=$(pwd); echo at $here\n"
        'echo "[$(echo a; echo b)]"\n'
        "echo $(echo one two) $(hello | upper)\n"
    )
    out = outputs(shell, typed)
    assert out[:3] == ["at /", "[a", "b]"]
    assert out[-1] == "one two HELLO FROM A BALANCED-TERNARY MACHINE"


def test_test_and_brackets(shell):
    on = bin_disk(notes="some words\n", empty="")
    typed = (
        "test -f notes && echo file\n"
        "[ -d bin ] && echo dir\n"
        "[ -s empty ] || echo empty\n"
        "[ -e nope ] || echo missing\n"
        '[ -z "" -a -n x ] && echo strings\n'
        "[ abc != abd ] && echo differ\n"
        "[ 3 -gt 10 ] || echo numbers\n"
        "[ ! 1 = 2 ] && echo not\n"
        "[ 1 = 1\necho $?\n"
    )
    assert outputs(shell, typed, on) == [
        "file",
        "dir",
        "empty",
        "missing",
        "strings",
        "differ",
        "numbers",
        "not",
        "sh: [: no ] at the end",
        "2",
    ]


def test_read_splits_lines_into_variables(shell):
    on = bin_disk(people="ann  lee 30\nbob\n")
    typed = (
        'while read first rest; do echo "<$first|$rest>"; done < people\n'
        "read a b < people; echo $a.$b\n"
    )
    assert outputs(shell, typed, on) == ["<ann|lee 30>", "<bob|>", "ann.lee 30"]


def test_patterns_match_files(shell):
    on = bin_disk(a1="", a2="", b1="", **{".hid": ""})
    typed = "echo a*\necho ?1\necho [ab]2 b[!1]\necho 'a*' a\\*\necho bin/e*\necho *d\n"
    assert outputs(shell, typed, on) == [
        "a1 a2",
        "a1 b1",
        "a2 b[!1]",
        "a* a*",
        "bin/echo",
        "*d",
    ]


def test_redirections_on_compound_commands_and_descriptors(shell):
    typed = (
        "{ echo one; echo two; } > out\ncat out\n"
        "for x in a b; do echo $x; done | wc\n"
        "if true; then echo inner; fi >> out\ncat out\n"
        "echo oops 2>e2 >&2\ncat e2\n"
        "nope 2> err\ncat err\n"
    )
    assert outputs(shell, typed) == [
        "one",
        "two",
        "2 2 4",
        "one",
        "two",
        "inner",
        "oops",
        "sh: no such program: nope",
    ]


def test_comments_and_continued_lines(shell):
    typed = (
        "echo a # not this\n"
        "# a whole line\n"
        "if true\nthen\n  echo b\nfi\n"
        "echo c \\\n d\n"
        "echo 'e\nf'\n"
        "for x in 1 2\ndo echo $x\ndone\n"
    )
    out = said(shell, typed)
    assert "> then\n> " in out
    assert outputs(shell, typed) == ["a", "b", "c d", "e", "f", "1", "2"]


def test_syntax_errors_are_said(shell):
    typed = "fi\necho $?\n| hello\nif true; then; fi\necho after\n"
    assert outputs(shell, typed) == [
        "sh: unexpected fi",
        "2",
        "sh: unexpected |",
        "sh: unexpected ;",
        "after",
    ]


SCRIPT = """#!/bin/sh
# a script
echo "$0 has $# arguments: $@"
total=0
for n in "$@"; do total=$((total + n)); done
echo total $total
shift
echo then $1
exit 4
"""


def test_scripts_from_files_and_strings(shell):
    on = bin_disk(add=SCRIPT, lib="hello_from() { echo hello from $1; }\nx=set\n")
    typed = (
        "sh add 1 2 3\necho $?\n"
        "./add 5 5\n"
        "sh -c 'echo $0 got $1' me it\n"
        ". lib\nhello_from lib; echo $x\n"
        "sh nope\necho $?\n"
    )
    assert outputs(shell, typed, on) == [
        "add has 3 arguments: 1 2 3",
        "total 6",
        "then 2",
        "sh: exit 4",
        "4",
        "./add has 2 arguments: 5 5",
        "total 10",
        "then 5",
        "sh: exit 4",
        "me got it",
        "hello from lib",
        "set",
        "sh: nope: no such file or directory",
        "sh: exit 127",
        "127",
    ]


def test_a_script_with_an_error_says_its_line(shell):
    on = bin_disk(bad="echo fine\n\nif then\necho never\n")
    assert outputs(shell, "sh bad\necho $?\n", on) == [
        "fine",
        "sh: bad: line 3: unexpected then",
        "sh: exit 2",
        "2",
    ]


def test_background_jobs_and_wait(shell):
    typed = (
        "sleep 9000000 &\njobs\nwait %1\necho waited $?\nhello &\nwait\necho $! > pid\n"
    )
    out = said(shell, typed)
    assert "[1] " in out
    assert "[1] running  sleep 9000000\n" in out
    assert "waited 0\n" in out
    assert "hello from a balanced-ternary machine\n" in out


def test_background_needs_programs(shell):
    assert outputs(shell, "cd / &\ntrue && hello &\n") == [
        "sh: only programs run in the background",
        "sh: only a pipeline of programs runs in the background",
    ]
