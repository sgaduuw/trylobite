"""Quoting in the shell: '...', "..." and \\ make characters themselves,
so an argument can hold a space and a quoted |, < or > neither pipes nor
redirects; "" alone is an empty argument."""

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk
from tests.test_args import said


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def test_quotes_keep_spaces_in_one_argument(shell):
    typed = "echo \"hello   world\" 'a  b' c\\ d\n"
    assert said(shell, typed) == f"$ {typed}hello   world a  b c d\n$ \n"


def test_quoted_pipes_and_redirections_are_characters(shell):
    typed = "echo \"a|b\" '<c>' x\\>y\n"
    assert said(shell, typed) == f"$ {typed}a|b <c> x>y\n$ \n"


def test_backslash_inside_double_quotes_quotes_only_quote_and_backslash(shell):
    typed = 'echo "say \\"hi\\"" "a\\b" "c\\\\" \'d\\\'\n'
    assert said(shell, typed) == f'$ {typed}say "hi" a\\b c\\ d\\\n$ \n'


def test_quotes_join_with_what_touches_them(shell):
    typed = "echo ab\"c d\"'e'f\n"
    assert said(shell, typed) == f"$ {typed}abc def\n$ \n"


def test_empty_quotes_are_an_empty_argument(shell):
    # a, "" and b: wc sees two words but both spaces between them.
    typed = "echo a \"\" b | wc\necho '' x\n"
    assert said(shell, typed) == "$ echo a \"\" b | wc\n1 2 5\n$ echo '' x\n x\n$ \n"


def test_an_unclosed_quote_is_refused(shell):
    typed = "echo \"oops\necho 'no\n"
    assert said(shell, typed) == (
        '$ echo "oops\nsh: a quote is not closed\n'
        "$ echo 'no\nsh: a quote is not closed\n$ \n"
    )


def test_a_quoted_command_and_redirection_path(shell):
    on = bin_disk(notes="quiet words\n")
    typed = '"echo" hi >\'out\'\ncat "out"\nwc <"notes"\n'
    assert said(shell, typed, on) == (
        '$ "echo" hi >\'out\'\n$ cat "out"\nhi\n$ wc <"notes"\n1 2 12\n$ \n'
    )


def test_write_keeps_quoted_text(shell):
    typed = 'write f one "  two |" three\ncat f\n'
    assert said(shell, typed) == (
        '$ write f one "  two |" three\n$ cat f\none   two | three\n$ \n'
    )
