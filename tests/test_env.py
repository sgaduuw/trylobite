"""The environment: NAME=value strings that every spawn copies from the
parent (the block its environ call named, or the one it started with)
to V_ENV in the child (include/layout.s), trystd::env over it, and the
shell's variables: NAME=value, export, unset, env, set, $NAME, ${NAME},
$? and $$, PATH and HOME."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image

RENV = ROOT / "tests" / "renv.rs"


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def said(shell, typed: str, disk=None) -> str:
    """What the shell said to typed, the kernel's messages left out."""
    result = run_image(shell, input=typed, disk=disk or bin_disk(), max_steps=20_000_000)
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_a_program_reads_changes_and_passes_on_its_environment(shell):
    out = said(shell, "export GREETING=hi\nrenv\n", bin_disk(programs=(RENV,)))
    assert out == (
        "$ export GREETING=hi\n"
        "$ renv\n"
        'start Ok("hi")\n'
        'vars [("PATH", "/bin"), ("HOME", "/"), ("A", "uno"), ("B", "two")]\n'
        "missing Err(NotPresent)\n"
        'child "PATH=/bin\\nHOME=/\\nA=uno\\nC=three\\n"\n'
        "after Err(NotPresent)\n"
        'name "" invalid argument\n'
        'name "x=y" invalid argument\n'
        "big environment too large\n"
        'kept Ok("uno")\n'
        "fault true\n"
        "unended true\n"
        'still "PATH=/bin\\nHOME=/\\nA=uno\\nB=two\\n"\n'
        "$ \n"
    )


def test_the_shell_starts_with_path_and_home(shell):
    assert said(shell, "env\necho $PATH $HOME\n") == (
        "$ env\nPATH=/bin\nHOME=/\n$ echo $PATH $HOME\n/bin /\n$ \n"
    )


def test_a_variable_is_the_shells_until_exported(shell):
    typed = (
        "A=one\necho $A ${A}s\nprintenv A\nexport A\nprintenv A\n"
        "export B='two words' C\nprintenv B C\nunset A B\nprintenv\n"
    )
    assert said(shell, typed) == (
        "$ A=one\n$ echo $A ${A}s\none ones\n"
        "$ printenv A\nsh: exit 1\n"
        "$ export A\n$ printenv A\none\n"
        "$ export B='two words' C\n$ printenv B C\ntwo words\n\n"
        "$ unset A B\n$ printenv\nPATH=/bin\nHOME=/\nC=\n$ \n"
    )


def test_assignments_before_a_command_are_for_it_alone(shell):
    typed = "X=1 Y=2 printenv X Y\nprintenv X\nX=3 env\necho $X.\n"
    assert said(shell, typed) == (
        "$ X=1 Y=2 printenv X Y\n1\n2\n"
        "$ printenv X\nsh: exit 1\n"
        "$ X=3 env\nPATH=/bin\nHOME=/\nX=3\n"
        "$ echo $X.\n.\n$ \n"
    )


def test_a_nested_shell_inherits_and_its_exports_stay_in_it(shell):
    typed = "export A=1\nsh\necho $A\nexport B=2\nexit\necho $A$B\n"
    assert said(shell, typed) == (
        "$ export A=1\n$ sh\n$ echo $A\n1\n$ export B=2\n$ exit\n$ echo $A$B\n1\n$ \n"
    )


def test_quoting_decides_expansion_and_splitting(shell):
    # Single quotes keep $ itself; double quotes expand but keep spaces;
    # a bare value splits, and an empty one is no argument at all.
    typed = (
        "V='a   b'\necho $V \"$V\" '$V' \\$V\n"
        "E=\necho x $E y \"$E\" | wc\necho $ \"$\" $1x\n"
    )
    assert said(shell, typed) == (
        "$ V='a   b'\n$ echo $V \"$V\" '$V' \\$V\n"
        "a b a   b $V $V\n"
        "$ E=\n$ echo x $E y \"$E\" | wc\n1 2 5\n"
        "$ echo $ \"$\" $1x\n$ $ $1x\n$ \n"
    )


def test_braces_defaults_and_lengths(shell):
    typed = "A=abc\nE=\necho ${A}d ${#A} ${E:-dflt} ${E-dflt}. ${N-unset} ${A:-no}\n"
    assert said(shell, typed).endswith("abcd 3 dflt . unset abc\n$ \n")


def test_status_and_process_number(shell):
    out = said(shell, "fail\necho $?\nnope\necho $?\necho $? $$\ncd /nowhere\necho $?\n")
    assert out == (
        "$ fail\nsh: exit 3\n$ echo $?\n3\n"
        "$ nope\nsh: no such program: nope\n$ echo $?\n127\n"
        "$ echo $? $$\n0 7\n"
        "$ cd /nowhere\nsh: /nowhere: no such file or directory\n$ echo $?\n1\n$ \n"
    )


def test_path_is_searched_in_order(shell):
    disk = bin_disk(programs=(RENV,))
    typed = "PATH=/nowhere\nhello\nPATH=/tmp:/bin\nhello\n/bin/hello\nunset PATH\nhello\n"
    out = said(shell, typed, disk)
    assert out == (
        "$ PATH=/nowhere\n$ hello\nsh: no such program: hello\n"
        "$ PATH=/tmp:/bin\n$ hello\nhello from a balanced-ternary machine\n"
        "$ /bin/hello\nhello from a balanced-ternary machine\n"
        "$ unset PATH\n$ hello\nhello from a balanced-ternary machine\n$ \n"
    )


def test_home_and_tilde(shell):
    typed = "mkdir h\nHOME=/h\ncd /bin\ncd\npwd\necho ~ ~/x a~\n"
    assert said(shell, typed).endswith("$ pwd\n/h\n$ echo ~ ~/x a~\n/h /h/x a~\n$ \n")


def test_export_and_set_list_variables(shell):
    typed = "A='x y'\nexport B=1\nexport\nset\n"
    assert said(shell, typed) == (
        "$ A='x y'\n$ export B=1\n$ export\n"
        "export PATH=/bin\nexport HOME=/\nexport B=1\n"
        "$ set\nPATH=/bin\nHOME=/\nA='x y'\nB=1\n$ \n"
    )


def test_export_refuses_what_is_not_a_name(shell):
    assert said(shell, "export 1A=2 =x\necho $?\n") == (
        "$ export 1A=2 =x\nsh: export: not a name: 1A\nsh: export: not a name: \n"
        "$ echo $?\n1\n$ \n"
    )
