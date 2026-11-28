"""The boot report (kernel/rust/trykern/src/boot.rs): what the kernel says
it found before it starts init, and init's lines in shell.s as it starts
each server."""

import tomllib

from tests.kernel import DONE, ROOT, assemble_file, bin_disk, new_disk, run, run_image


def report(console: str) -> list[str]:
    """The kernel's boot report, up to and with "starting init"."""
    head, found, _ = console.partition("trylobite: starting init\n")
    assert found, console
    return (head + found).splitlines()


def test_the_kernel_says_what_it_found_before_it_starts_init(harts):
    result = run(DONE, ram_pages=40, disk=(new_disk(), 5))
    assert result.exit_code == 0, result.console
    free = 40 - result.image.symbols["P_FREE"]  # + 1, less the log's page
    assert report(result.console) == [
        "trylobite: version 0.1.0, a microkernel for detrytus, the "
        "balanced-ternary machine",
        f"trylobite: memory: 40 pages ({40 * 19683} trytes), {free} free",
        f"trylobite: harts: {harts}",
        "trylobite: irq0: interrupt controller, 3 sources, at page -13",
        "trylobite: cons0: console, at page -1",
        "trylobite: disk0: block device, 5 blocks, at page -14",
        "trylobite: net0: network device, no link, at page -16",
        "trylobite: process table: 27 slots, 3 programs in the image",
        "trylobite: starting init",
    ]


def test_no_disk_is_said():
    lines = report(run(DONE).console)
    assert "trylobite: disk0: block device, no disk, at page -14" in lines


def test_the_network_device_says_its_address_with_a_link():
    lines = report(run(DONE, link="loop").console)
    line = "trylobite: net0: network device, 02:00:00:00:00:01, at page -16"
    assert line in lines


def test_the_version_is_the_package_version():
    project = tomllib.loads((ROOT / "pyproject.toml").read_text())["project"]
    line = report(run(DONE).console)[0]
    assert line.startswith(f"trylobite: version {project['version']}, ")


def test_init_says_each_server_it_starts_and_then_the_shell():
    result = run_image(assemble_file(ROOT / "shell.s"), input="", disk=bin_disk())
    assert result.exit_code == 0, result.console
    after = result.console.partition("trylobite: starting init\n")[2]
    assert after.startswith(
        "init: started console, process 1\n"
        "init: started disk, process 2\n"
        "init: started fs, process 3\n"
        "init: started pipe, process 4\n"
        "init: started net, process 5\n"
        "init: started ip, process 6\n"
        "init: starting sh\n"
        "$ "
    ), after


def boot_from(disk: tuple, session: str, harts: int) -> tuple[int, str]:
    """`detrytus run --disk` with no program: detrytus' boot ROM loads the
    kernel from the disk's boot blocks. The exit status and the console."""
    from tests.kernel import detrytus, disk_options, input_options

    done = detrytus(
        "run",
        "--ram-pages",
        "243",
        "--harts",
        str(harts),
        *input_options(session),
        *disk_options(disk),
    )
    return done.returncode, done.stdout


def bootable_disk(**texts: str) -> tuple:
    """bin_disk with shell.s, the kernel, in its boot blocks (tools/fs.py
    new --boot, as make builds disk.img)."""
    from tools.fs import Filesystem, boot_image

    path, blocks = bin_disk(blocks=80, **texts)
    made = Filesystem.load(path)
    made.set_boot(boot_image(assemble_file(ROOT / "shell.s").path.read_bytes()))
    made.save(path)
    return path, blocks


def test_the_kernel_boots_from_the_disk(harts):
    disk = bootable_disk(notes="kept on the disk\n")
    status, console = boot_from(disk, "hello\ncat notes\nexit\n", harts)
    assert status == 0, console
    assert report(console)[0].startswith("trylobite: version")
    assert f"trylobite: harts: {harts}" in console
    shell = console.partition("init: starting sh\n")[2]
    assert "hello from a balanced-ternary machine\n" in shell
    assert "kept on the disk\n" in shell
    assert "trylobite: all processes exited" in shell


def test_the_same_disk_runs_with_the_kernel_loaded_as_a_file():
    disk = bootable_disk()
    result = run_image(
        assemble_file(ROOT / "shell.s"), input="hello\nexit\n", disk=disk
    )
    assert result.exit_code == 0, result.console
    assert "hello from a balanced-ternary machine\n" in result.after_boot


def test_a_disk_without_a_kernel_does_not_boot():
    status, console = boot_from(bin_disk(), "", 1)
    assert (status, console) == (1, "boot: no boot record in block 0\n")
