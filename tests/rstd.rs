//! rstd [net | threads]: a test of trystd, the Rust system library, from
//! the inside: each check prints a line saying what it found, which
//! tests/test_trystd.py compares with what it should be. With `net`, the
//! sockets too, against the IP server's echo service on port 7 (a
//! machine with a link); with `threads`, threads and their locks alone.
#![no_std]

use trystd::fs::{self, File, OpenOptions};
use trystd::io::{BufReader, SeekFrom};
use trystd::net::{Ipv4Addr, TcpStream, UdpSocket};
use trystd::prelude::*;
use trystd::process::{Command, Stdio};
use trystd::sync::{Arc, Condvar, Mutex};

trystd::main!(run);

fn run() -> io::Result<()> {
    let args: Vec<&str> = env::args().collect();
    println!("args {args:?}");
    if args.get(1) == Some(&"threads") {
        threads()?;
        println!("done");
        return Ok(());
    }
    files()?;
    directories()?;
    processes()?;
    if args.get(1) == Some(&"net") {
        sockets()?;
    }
    println!("done");
    Ok(())
}

fn files() -> io::Result<()> {
    fs::write("/t1", "one\ntwo\n")?;
    let mut f = OpenOptions::new().append(true).open("/t1")?;
    writeln!(f, "three {}", 3)?;
    drop(f);
    println!("read {:?}", fs::read_to_string("/t1")?);
    println!("len {}", fs::metadata("/t1")?.len());
    let lines: Vec<String> = BufReader::new(File::open("/t1")?)
        .lines()
        .collect::<io::Result<_>>()?;
    println!("lines {lines:?}");
    let mut f = File::open("/t1")?;
    f.seek(SeekFrom::Start(4))?;
    let mut word = [0u8; 3];
    f.read_exact(&mut word)?;
    println!(
        "seek {:?} at {}",
        core::str::from_utf8(&word).unwrap(),
        f.stream_position()?
    );
    match File::open("/missing") {
        Ok(_) => println!("missing opened"),
        Err(e) => println!("missing {:?}: {e}", e.kind()),
    }
    match OpenOptions::new().write(true).create_new(true).open("/t1") {
        Ok(_) => println!("create_new made it"),
        Err(e) => println!("create_new {:?}", e.kind()),
    }
    match File::create("/t1").and_then(|mut f| f.read(&mut word)) {
        Ok(_) => println!("read a write-only file"),
        Err(e) => println!("write-only read: {e}"),
    }
    println!("copy {}", fs::copy("/notes", "/t2")?);
    fs::rename("/t2", "/t3")?;
    println!(
        "renamed {} {}",
        fs::exists("/t2")?,
        fs::read_to_string("/t3")?.trim_end()
    );
    fs::remove_file("/t3")?;
    println!("removed {}", fs::exists("/t3")?);
    Ok(())
}

fn directories() -> io::Result<()> {
    fs::create_dir("/d")?;
    fs::write("/d/b", "bee")?;
    fs::create_dir("/d/a")?;
    env::set_current_dir("/d")?;
    println!("cwd {}", env::current_dir()?);
    println!("relative {}", fs::read_to_string("b")?);
    let mut names: Vec<String> = fs::read_dir(".")?
        .map(|e| {
            let e = e?;
            Ok(format!(
                "{}{}",
                e.file_name(),
                if e.metadata()?.is_dir() { "/" } else { "" }
            ))
        })
        .collect::<io::Result<_>>()?;
    names.sort();
    println!("entries {names:?}");
    match fs::remove_dir("/d") {
        Ok(()) => println!("removed a full directory"),
        Err(e) => println!("remove_dir: {e}"),
    }
    env::set_current_dir("/")?;
    fs::remove_file("/d/b")?;
    fs::remove_dir("/d/a")?;
    fs::remove_dir("/d")?;
    println!("gone {}", fs::exists("/d")?);
    Ok(())
}

fn processes() -> io::Result<()> {
    let out = Command::new("echo").args(["from", "a child"]).output()?;
    println!(
        "output {:?} {}",
        String::from_utf8_lossy(&out.stdout),
        out.status
    );
    let status = Command::new("/bin/fail").status()?;
    println!("fail {status} {:?} {}", status.code(), status.success());
    let mut child = Command::new("wc")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(b"one two\nthree\n")?;
    let out = child.wait_with_output()?;
    println!("wc {:?}", String::from_utf8_lossy(&out.stdout));
    Command::new("echo")
        .arg("into a file")
        .stdout(File::create("/t4")?)
        .status()?;
    println!("redirected {:?}", fs::read_to_string("/t4")?);
    match Command::new("nosuch").status() {
        Ok(s) => println!("nosuch ran: {s}"),
        Err(e) => println!("nosuch: {e}"),
    }
    // This program's own standard output is as it was.
    println!("still here, process {}", trystd::process::id() > 0);
    machine()
}

fn machine() -> io::Result<()> {
    use trystd::os;
    let me = os::process(trystd::process::id()).map(|p| (p.name().to_string(), p.state));
    println!("os me {me:?}");
    let init = os::process(0).map(|p| (p.name().to_string(), p.parent));
    println!("os init {init:?}");
    let info = os::info();
    println!(
        "os info {} {} {}",
        info.free_pages() <= info.pages(),
        info.processes() >= 9,
        info.release()
    );
    println!("os log {}", os::log()?.starts_with(b"trylobite: "));
    println!("os hart {}", os::hart(0).is_some_and(|h| h.started <= h.time));
    Ok(())
}

fn sockets() -> io::Result<()> {
    let ours = trystd::net::local_address()?;
    println!("address {ours}");
    let c = trystd::net::config()?;
    let gateway = c.gateway.map(|g| g.to_string());
    println!("config {}/{} {gateway:?}", c.address, c.prefix);
    println!("ping {}", trystd::net::ping(ours, 1, 100_000).is_ok());
    let mut udp = UdpSocket::bind("0.0.0.0:0")?;
    udp.set_read_timeout_ticks(Some(2_000_000))?;
    udp.send_to(b"ping over udp", (ours, 7))?;
    let mut buf = [0u8; 64];
    let (n, from) = udp.recv_from(&mut buf)?;
    println!(
        "udp {:?} from port {}",
        core::str::from_utf8(&buf[..n]).unwrap(),
        from.port()
    );
    let mut tcp = TcpStream::connect((ours, 7))?;
    tcp.write_all(b"ping over tcp")?;
    tcp.shutdown(trystd::net::Shutdown::Write)?;
    let mut back = String::new();
    tcp.read_to_string(&mut back)?;
    println!("tcp {back:?} from {}", tcp.peer_addr()?);
    match TcpStream::connect("10.0.0.2:9000") {
        Ok(_) => println!("port 9000 answered"),
        Err(e) => println!("port 9000: {e}"),
    }
    println!(
        "parse {:?} {}",
        "1.2.3".parse::<Ipv4Addr>().is_err(),
        Ipv4Addr::new(192, 0, 2, 200)
    );
    Ok(())
}

fn threads() -> io::Result<()> {
    let h = thread::spawn(|| 6 * 7);
    println!("joined {}", h.join()?);

    // A count three threads add to, behind a lock.
    let n = Arc::new(Mutex::new(0u32));
    let hs: Vec<_> = (0..3)
        .map(|_| {
            let n = n.clone();
            thread::spawn(move || {
                for _ in 0..200 {
                    *n.lock().unwrap() += 1;
                    thread::yield_now();
                }
            })
        })
        .collect();
    for h in hs {
        h.join()?;
    }
    println!("counted {}", *n.lock().unwrap());

    // A thread asleep on a Condvar until the flag is set.
    let pair = Arc::new((Mutex::new(false), Condvar::new()));
    let theirs = pair.clone();
    let h = thread::spawn(move || {
        let (m, c) = &*theirs;
        *c.wait_while(m.lock().unwrap(), |ready| !*ready).unwrap()
    });
    {
        let (m, c) = &*pair;
        *m.lock().unwrap() = true;
        c.notify_one();
    }
    println!("woken {}", h.join()?);

    // Its own number, its process's, and its process's directory.
    let (tid, pid) = thread::spawn(|| (thread::current_id(), trystd::process::id())).join()?;
    println!(
        "numbers: own {} process same {}",
        tid != pid as i32,
        pid == trystd::process::id()
    );
    fs::create_dir("/thr")?;
    env::set_current_dir("/thr")?;
    fs::write("f", "in thr\n")?;
    let read = thread::spawn(|| fs::read_to_string("f")).join()?;
    println!("relative {read:?}");
    env::set_current_dir("/")?;

    // More threads than the process table has slots, half of them let
    // go without join: their slots come back all the same.
    for k in 0..40 {
        let h = thread::Builder::new().stack_size(1000).spawn(move || k)?;
        if k % 2 == 0 {
            drop(h);
            thread::yield_now();
        } else {
            h.join()?;
        }
    }
    println!("forty threads");
    thread::spawn(|| println!("printed by a thread")).join()?;
    Ok(())
}
