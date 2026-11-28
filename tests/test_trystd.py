"""trystd, the system library for Rust programs (lib/rust/trystd): its
files, processes and sockets as tests/rstd.rs finds them from inside a
program, and the tools written over it (bin/tee, xargs, fetch, httpd)
in the shell."""

import re

import pytest

from tests.kernel import ROOT, assemble_file, bin_disk, run_image
from tools.fs import Filesystem

RSTD = ROOT / "tests" / "rstd.rs"
NOTES = "hello notes\n"


@pytest.fixture(scope="module")
def shell():
    return assemble_file(ROOT / "shell.s")


def session(shell, typed: str, disk=None, link=None, max_steps=60_000_000):
    """What the shell said to typed, the kernel's messages left out."""
    disk = disk or bin_disk(programs=(RSTD,), notes=NOTES)
    result = run_image(shell, input=typed, disk=disk, link=link, max_steps=max_steps)
    assert result.exit_code == 0, result.console
    return re.sub(r"trylobite: [^\n]*\n", "", result.after_boot)


def test_files_directories_and_processes_from_rust(shell):
    out = session(shell, "rstd one\n")
    assert out == (
        "$ rstd one\n"
        'args ["rstd", "one"]\n'
        'read "one\\ntwo\\nthree 3\\n"\n'
        "len 16\n"
        'lines ["one", "two", "three 3"]\n'
        'seek "two" at 7\n'
        "missing NotFound: no such file or directory\n"
        "create_new AlreadyExists\n"
        "write-only read: bad descriptor\n"
        f"copy {len(NOTES)}\n"
        "renamed false hello notes\n"
        "removed false\n"
        "cwd /d\n"
        "relative bee\n"
        'entries ["a/", "b"]\n'
        "remove_dir: directory not empty\n"
        "gone false\n"
        'output "from a child\\n" exit 0\n'
        "fail exit 3 Some(3) false\n"
        'wc "2 3 14\\n"\n'
        'redirected "into a file\\n"\n'
        "nosuch: no such file or directory\n"
        "still here, process true\n"
        'os me Some(("rstd", Running))\n'
        'os init Some(("init", None))\n'
        "os info true true 0.1.0\n"
        "os log true\n"
        "os hart true\n"
        "instant true true true true\n"
        "done\n"
        "$ \n"
    )


def test_sockets_from_rust(shell):
    out = session(shell, "rstd net\n", link="loop")
    assert out.split("instant true true true true\n")[1] == (
        "address 10.0.0.2\n"
        'config 10.0.0.2/24 Some("10.0.0.1")\n'
        "ping true\n"
        'udp "ping over udp" from port 7\n'
        'tcp "ping over tcp" from 10.0.0.2:7\n'
        "port 9000: connection refused\n"
        "parse true 192.0.2.200\n"
        "done\n"
        "$ \n"
    )


def test_threads_and_locks_from_rust(shell):
    out = session(shell, "rstd threads\n")
    assert out == (
        "$ rstd threads\n"
        'args ["rstd", "threads"]\n'
        "joined 42\n"
        "counted 600\n"
        "woken true\n"
        "numbers: own true process same true\n"
        'relative Ok("in thr\\n")\n'
        "forty threads\n"
        "printed by a thread\n"
        "done\n"
        "$ \n"
    )


def test_threads_on_two_harts_count_primes(shell):
    # bin/rthreads: two threads share a tally behind a Mutex; with more
    # than one hart they run on two at once.
    disk = bin_disk()
    result = run_image(shell, input="rthreads 3000\n", disk=disk, max_steps=60_000_000)
    assert result.exit_code == 0, result.console
    out = result.after_boot
    assert "primes below 3000: 430\n" in out
    harts = 1 if result.harts == 1 else 2
    assert f"harts used: {harts}\n" in out


def test_tee_copies_to_files_too(shell):
    disk = bin_disk(notes=NOTES)
    out = session(
        shell,
        "echo hi | tee t1 t2\necho more | tee -a t2 /nodir/x\ncat t1\n",
        disk,
    )
    assert out == (
        "$ echo hi | tee t1 t2\nhi\n"
        "$ echo more | tee -a t2 /nodir/x\n"
        "tee: /nodir/x: no such file or directory\nmore\nsh: exit 1\n"
        "$ cat t1\nhi\n$ \n"
    )
    assert Filesystem.load(disk[0]).read("t2") == "hi\nmore\n"


def test_xargs_runs_a_command_on_the_words_it_reads(shell):
    # 100 words of 9 letters take 1,000 trytes as arguments: more than
    # ARG_MAX (243), so echo runs as many times as it takes.
    words = " ".join(f"word{k:05}" for k in range(100))
    disk = bin_disk(notes=NOTES, words=words + "\n", empty="")
    out = session(
        shell,
        "echo a b  c | xargs echo x\nxargs < words | wc\n"
        "xargs echo nothing < empty\nxargs nosuch < notes\n"
        "echo 3 | xargs fail\n",
        disk,
    )
    assert out == (
        "$ echo a b  c | xargs echo x\nx a b c\n"
        "$ xargs < words | wc\n5 100 1000\n"
        "$ xargs echo nothing < empty\nnothing\n"
        "$ xargs nosuch < notes\nxargs: nosuch: no such file or directory\n"
        "sh: exit 127\n"
        "$ echo 3 | xargs fail\nsh: exit 123\n$ \n"
    )


def test_httpd_serves_files_that_fetch_gets(shell):
    # httpd says its URL and closes standard output; fetch - reads it,
    # by which time httpd listens.
    disk = bin_disk(notes=NOTES)
    out = session(
        shell,
        "httpd -n 1 notes | fetch -\nhttpd -n 1 / | fetch -i -\n"
        "httpd -n 1 -p 8080 nope | fetch -\nfetch http://10.0.0.2:9/\n"
        "fetch ftp://x\nhttpd -p 0\n",
        disk,
        link="loop",
    )
    assert out == (
        "$ httpd -n 1 notes | fetch -\n"
        "httpd: 10.0.0.2:49152 GET /notes HTTP/1.0 200\n"
        f"{NOTES}"
        "$ httpd -n 1 / | fetch -i -\n"
        "httpd: 10.0.0.2:49153 GET / HTTP/1.0 200\n"
        "HTTP/1.0 200 OK\nContent-Type: text/plain\nContent-Length: 11\n\n"
        "bin/\nnotes\n"
        "$ httpd -n 1 -p 8080 nope | fetch -\n"
        "httpd: 10.0.0.2:49154 GET /nope HTTP/1.0 404\n"
        "not found\nfetch: http://10.0.0.2:8080/nope: 404 Not Found\nsh: exit 1\n"
        "$ fetch http://10.0.0.2:9/\n"
        "fetch: http://10.0.0.2:9/: connection refused\nsh: exit 1\n"
        "$ fetch ftp://x\nfetch: ftp://x: only http:// URLs\nsh: exit 1\n"
        "$ httpd -p 0\nusage: httpd [-n COUNT] [-p PORT] [PATH]\nsh: exit 2\n$ \n"
    )
