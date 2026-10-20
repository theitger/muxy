//! muxyd keeps muxy's terminal sessions running while muxy itself quits,
//! updates or crashes, the way dtach or tmux keep theirs.
//!
//! A tab in muxy runs `muxyd attach`, a small client between Ghostty and
//! the session. The session's program (an agent, a shell) runs in a
//! pseudo-terminal the daemon holds. When muxy goes away only the client
//! ends; the next `muxyd attach` with the same id finds the program still
//! running, gets what it printed meanwhile, and goes on. `muxyd kill`
//! ends a session for good (a tab you close).
//!
//!   muxyd attach --socket PATH --id ID [--cwd DIR] -- PROGRAM [ARGS…]
//!   muxyd kill   --socket PATH --id ID
//!   muxyd list   --socket PATH
//!   muxyd serve  --socket PATH          (started by attach when needed)
//!
//! Frames on the socket: one byte of type, four of length (big-endian),
//! then the payload.

use std::collections::{HashMap, VecDeque};
use std::ffi::CString;
use std::io::{Read, Write};
use std::os::fd::RawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const HELLO: u8 = 1;
const INPUT: u8 = 2;
const OUTPUT: u8 = 3;
const RESIZE: u8 = 4;
const EXIT: u8 = 5;
const KILL: u8 = 6;
const LIST: u8 = 7;
const INFO: u8 = 8;

/// What a session printed last, replayed to the next client that attaches.
const REPLAY: usize = 512 * 1024;
/// A daemon without sessions goes away after this.
const IDLE: Duration = Duration::from_secs(30);

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("");
    let socket = option(&args, "--socket").map(PathBuf::from).unwrap_or_else(default_socket);
    let code = match command {
        "serve" => serve(&socket),
        "attach" => attach(&socket, &args),
        "kill" => kill(&socket, &args),
        "list" => list(&socket),
        _ => {
            eprintln!("usage: muxyd attach|kill|list|serve --socket PATH …");
            2
        }
    };
    std::process::exit(code);
}

fn option(args: &[String], name: &str) -> Option<String> {
    let end = args.iter().position(|a| a == "--").unwrap_or(args.len());
    args[..end].iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn default_socket() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".local/state/muxy/muxyd.sock")
}

// MARK: Frames

fn send(stream: &mut UnixStream, kind: u8, payload: &[u8]) -> std::io::Result<()> {
    let mut frame = Vec::with_capacity(5 + payload.len());
    frame.push(kind);
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(payload);
    stream.write_all(&frame)
}

fn receive(stream: &mut UnixStream) -> std::io::Result<(u8, Vec<u8>)> {
    let mut head = [0u8; 5];
    stream.read_exact(&mut head)?;
    let len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
    if len > 64 * 1024 * 1024 {
        return Err(std::io::Error::new(std::io::ErrorKind::InvalidData, "frame too large"));
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload)?;
    Ok((head[0], payload))
}

/// key/value pairs, \x1f between key and value, \x1e between pairs.
fn encode(fields: &[(String, String)]) -> Vec<u8> {
    fields.iter().map(|(k, v)| format!("{k}\x1f{v}")).collect::<Vec<_>>().join("\x1e").into_bytes()
}

fn decode(payload: &[u8]) -> Vec<(String, String)> {
    String::from_utf8_lossy(payload)
        .split('\x1e')
        .filter_map(|pair| pair.split_once('\x1f').map(|(k, v)| (k.to_string(), v.to_string())))
        .collect()
}

// MARK: The daemon

struct Session {
    master: RawFd,
    pid: libc::pid_t,
    replay: Mutex<VecDeque<u8>>,
    client: Mutex<Option<UnixStream>>,
}

type Sessions = Arc<Mutex<HashMap<String, Arc<Session>>>>;

fn serve(socket: &Path) -> i32 {
    if let Some(parent) = socket.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // A socket nobody answers on is a daemon that died: take its place.
    if UnixStream::connect(socket).is_ok() {
        return 0;
    }
    let _ = std::fs::remove_file(socket);
    let listener = match UnixListener::bind(socket) {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("muxyd: can't listen on {}: {error}", socket.display());
            return 1;
        }
    };
    unsafe { libc::chmod(CString::new(socket.as_os_str().as_encoded_bytes()).unwrap().as_ptr(), 0o600) };
    unsafe { libc::signal(libc::SIGPIPE, libc::SIG_IGN) };
    let sessions: Sessions = Arc::new(Mutex::new(HashMap::new()));
    let last_seen = Arc::new(Mutex::new(Instant::now()));

    // Gone when nothing has run for a while.
    {
        let sessions = sessions.clone();
        let last_seen = last_seen.clone();
        let socket = socket.to_path_buf();
        thread::spawn(move || loop {
            thread::sleep(Duration::from_secs(5));
            let empty = sessions.lock().unwrap().is_empty();
            if !empty {
                *last_seen.lock().unwrap() = Instant::now();
            } else if last_seen.lock().unwrap().elapsed() > IDLE {
                let _ = std::fs::remove_file(&socket);
                std::process::exit(0);
            }
        });
    }

    for stream in listener.incoming().flatten() {
        *last_seen.lock().unwrap() = Instant::now();
        let sessions = sessions.clone();
        thread::spawn(move || handle(stream, sessions));
    }
    0
}

fn handle(mut stream: UnixStream, sessions: Sessions) {
    let Ok((kind, payload)) = receive(&mut stream) else { return };
    match kind {
        HELLO => hello(stream, &payload, sessions),
        KILL => {
            let id = String::from_utf8_lossy(&payload).to_string();
            if let Some(session) = sessions.lock().unwrap().remove(&id) {
                end(&session);
            }
            let _ = send(&mut stream, INFO, b"killed");
        }
        LIST => {
            let ids: Vec<String> = sessions.lock().unwrap().keys().cloned().collect();
            let _ = send(&mut stream, INFO, ids.join("\n").as_bytes());
        }
        _ => {}
    }
}

fn hello(mut stream: UnixStream, payload: &[u8], sessions: Sessions) {
    let fields = decode(payload);
    let get = |key: &str| fields.iter().find(|(k, _)| k == key).map(|(_, v)| v.clone());
    let Some(id) = get("id") else { return };
    let rows = get("rows").and_then(|v| v.parse().ok()).unwrap_or(24u16);
    let cols = get("cols").and_then(|v| v.parse().ok()).unwrap_or(80u16);

    let existing = sessions.lock().unwrap().get(&id).cloned();
    let (session, attached_again) = match existing {
        Some(session) => (session, true),
        None => {
            let argv: Vec<String> = fields.iter().filter(|(k, _)| k == "arg").map(|(_, v)| v.clone()).collect();
            let env: Vec<String> = fields.iter().filter(|(k, _)| k == "env").map(|(_, v)| v.clone()).collect();
            let cwd = get("cwd").unwrap_or_else(|| "/".into());
            if argv.is_empty() {
                let _ = send(&mut stream, INFO, b"nothing to run");
                return;
            }
            match spawn(&argv, &env, &cwd, rows, cols) {
                Ok((master, pid)) => {
                    let session = Arc::new(Session {
                        master,
                        pid,
                        replay: Mutex::new(VecDeque::with_capacity(REPLAY)),
                        client: Mutex::new(None),
                    });
                    sessions.lock().unwrap().insert(id.clone(), session.clone());
                    let reader = session.clone();
                    let all = sessions.clone();
                    let key = id.clone();
                    thread::spawn(move || pump(reader, all, key));
                    (session, false)
                }
                Err(error) => {
                    let _ = send(&mut stream, INFO, format!("can't start {}: {error}", argv[0]).as_bytes());
                    let _ = send(&mut stream, EXIT, &127i32.to_be_bytes());
                    return;
                }
            }
        }
    };

    // The newest client is the one that shows it.
    {
        let mut client = session.client.lock().unwrap();
        if let Some(mut old) = client.take() {
            let _ = send(&mut old, INFO, b"attached elsewhere");
            let _ = old.shutdown(std::net::Shutdown::Both);
        }
        if attached_again {
            // What it printed meanwhile, on a clean screen.
            let replay: Vec<u8> = session.replay.lock().unwrap().iter().copied().collect();
            let mut screen = b"\x1b[H\x1b[2J".to_vec();
            screen.extend_from_slice(&replay);
            let _ = send(&mut stream, OUTPUT, &screen);
        }
        *client = stream.try_clone().ok();
    }
    resize(session.master, rows, cols, attached_again);

    // Keys and sizes from the client until it goes (muxy quit: the
    // session stays).
    loop {
        match receive(&mut stream) {
            Ok((INPUT, bytes)) => {
                let _ = write_all(session.master, &bytes);
            }
            Ok((RESIZE, size)) if size.len() == 4 => {
                resize(session.master, u16::from_be_bytes([size[0], size[1]]), u16::from_be_bytes([size[2], size[3]]), false);
            }
            Ok(_) => {}
            Err(_) => break,
        }
    }
    let mut client = session.client.lock().unwrap();
    if let Some(current) = client.as_ref() {
        if current.peer_addr().is_err() || same(current, &stream) {
            *client = None;
        }
    }
}

fn same(a: &UnixStream, b: &UnixStream) -> bool {
    use std::os::fd::AsRawFd;
    let (mut sa, mut sb): (libc::stat, libc::stat) = unsafe { (std::mem::zeroed(), std::mem::zeroed()) };
    unsafe {
        libc::fstat(a.as_raw_fd(), &mut sa) == 0 && libc::fstat(b.as_raw_fd(), &mut sb) == 0 && sa.st_ino == sb.st_ino
    }
}

/// The program's output: kept for the next attach, passed to the client.
/// At its end, the exit status to the client and the session gone.
fn pump(session: Arc<Session>, sessions: Sessions, id: String) {
    let mut buffer = [0u8; 65536];
    loop {
        let n = unsafe { libc::read(session.master, buffer.as_mut_ptr() as *mut libc::c_void, buffer.len()) };
        if n < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        if n <= 0 {
            break;
        }
        let bytes = &buffer[..n as usize];
        {
            let mut replay = session.replay.lock().unwrap();
            replay.extend(bytes);
            let over = replay.len().saturating_sub(REPLAY);
            replay.drain(..over);
        }
        let mut client = session.client.lock().unwrap();
        if let Some(stream) = client.as_mut() {
            if send(stream, OUTPUT, bytes).is_err() {
                *client = None;
            }
        }
    }
    let mut status: libc::c_int = 0;
    unsafe { libc::waitpid(session.pid, &mut status, 0) };
    let code = if libc::WIFEXITED(status) { libc::WEXITSTATUS(status) } else { 128 + libc::WTERMSIG(status) };
    sessions.lock().unwrap().remove(&id);
    if let Some(stream) = session.client.lock().unwrap().as_mut() {
        let _ = send(stream, EXIT, &code.to_be_bytes());
    }
    unsafe { libc::close(session.master) };
}

fn spawn(argv: &[String], env: &[String], cwd: &str, rows: u16, cols: u16) -> std::io::Result<(RawFd, libc::pid_t)> {
    let program = CString::new(argv[0].clone())?;
    let args: Vec<CString> = argv.iter().map(|a| CString::new(a.as_str())).collect::<Result<_, _>>()?;
    let vars: Vec<CString> = env.iter().map(|e| CString::new(e.as_str())).collect::<Result<_, _>>()?;
    let dir = CString::new(cwd)?;
    let mut size = libc::winsize { ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0 };
    let mut master: libc::c_int = -1;
    let pid = unsafe { libc::forkpty(&mut master, std::ptr::null_mut(), std::ptr::null_mut(), &mut size) };
    if pid < 0 {
        return Err(std::io::Error::last_os_error());
    }
    if pid == 0 {
        // The child: its own session (forkpty), folder, environment, program.
        unsafe {
            libc::signal(libc::SIGPIPE, libc::SIG_DFL);
            if libc::chdir(dir.as_ptr()) != 0 {
                libc::chdir(c"/".as_ptr());
            }
            let mut arg_ptrs: Vec<*const libc::c_char> = args.iter().map(|a| a.as_ptr()).collect();
            arg_ptrs.push(std::ptr::null());
            let mut env_ptrs: Vec<*const libc::c_char> = vars.iter().map(|e| e.as_ptr()).collect();
            env_ptrs.push(std::ptr::null());
            libc::execve(program.as_ptr(), arg_ptrs.as_ptr(), env_ptrs.as_ptr());
            libc::_exit(127);
        }
    }
    Ok((master, pid))
}

/// Sets the terminal's size. `redraw`: a second, changed size first, so a
/// full-screen program (an agent) draws itself again for the new client.
fn resize(master: RawFd, rows: u16, cols: u16, redraw: bool) {
    let set = |r: u16, c: u16| {
        let size = libc::winsize { ws_row: r, ws_col: c, ws_xpixel: 0, ws_ypixel: 0 };
        unsafe { libc::ioctl(master, libc::TIOCSWINSZ, &size) };
    };
    if redraw && cols > 2 {
        set(rows, cols - 1);
        thread::sleep(Duration::from_millis(30));
    }
    set(rows, cols);
}

fn write_all(fd: RawFd, mut bytes: &[u8]) -> std::io::Result<()> {
    while !bytes.is_empty() {
        let n = unsafe { libc::write(fd, bytes.as_ptr() as *const libc::c_void, bytes.len()) };
        if n < 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(error);
        }
        bytes = &bytes[n as usize..];
    }
    Ok(())
}

/// The program's whole process group: SIGHUP as a closed terminal would,
/// then SIGKILL for one that doesn't listen.
fn end(session: &Session) {
    unsafe {
        libc::kill(-session.pid, libc::SIGHUP);
        libc::kill(session.pid, libc::SIGHUP);
    }
    let pid = session.pid;
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(3));
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
            libc::kill(pid, libc::SIGKILL);
        }
    });
}

// MARK: The client

fn connect(socket: &Path) -> Option<UnixStream> {
    if let Ok(stream) = UnixStream::connect(socket) {
        return Some(stream);
    }
    // No daemon yet: one of its own, apart from this terminal.
    let exe = std::env::current_exe().ok()?;
    let mut daemon = std::process::Command::new(exe);
    daemon
        .args(["serve", "--socket"])
        .arg(socket)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    unsafe {
        daemon.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    daemon.spawn().ok()?;
    for _ in 0..60 {
        thread::sleep(Duration::from_millis(50));
        if let Ok(stream) = UnixStream::connect(socket) {
            return Some(stream);
        }
    }
    None
}

fn window_size() -> (u16, u16) {
    let mut size: libc::winsize = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(0, libc::TIOCGWINSZ, &mut size) } == 0 && size.ws_row > 0 && size.ws_col > 0 {
        (size.ws_row, size.ws_col)
    } else {
        (24, 80)
    }
}

struct RawMode(Option<libc::termios>);

impl RawMode {
    fn enter() -> RawMode {
        let mut original: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(0, &mut original) } != 0 {
            return RawMode(None);
        }
        let mut raw = original;
        unsafe {
            libc::cfmakeraw(&mut raw);
            libc::tcsetattr(0, libc::TCSANOW, &raw);
        }
        RawMode(Some(original))
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        if let Some(original) = self.0 {
            unsafe { libc::tcsetattr(0, libc::TCSANOW, &original) };
        }
    }
}

fn attach(socket: &Path, args: &[String]) -> i32 {
    let Some(id) = option(args, "--id") else {
        eprintln!("muxyd attach: --id is missing");
        return 2;
    };
    let program: Vec<String> = args.iter().skip_while(|a| *a != "--").skip(1).cloned().collect();
    let cwd = option(args, "--cwd")
        .or_else(|| std::env::current_dir().ok().map(|d| d.to_string_lossy().to_string()))
        .unwrap_or_else(|| "/".into());
    let Some(mut stream) = connect(socket) else {
        // Without the daemon the program still runs, only not kept.
        if program.is_empty() {
            return 1;
        }
        let error = std::process::Command::new(&program[0]).args(&program[1..]).current_dir(&cwd).exec();
        eprintln!("muxyd: {error}");
        return 127;
    };

    let (rows, cols) = window_size();
    let mut fields = vec![
        ("id".to_string(), id),
        ("cwd".to_string(), cwd),
        ("rows".to_string(), rows.to_string()),
        ("cols".to_string(), cols.to_string()),
    ];
    // The program gets the terminal's environment, as if Ghostty ran it.
    let resolved = program.first().map(|p| resolve(p)).unwrap_or_default();
    for (i, arg) in program.iter().enumerate() {
        fields.push(("arg".into(), if i == 0 { resolved.clone() } else { arg.clone() }));
    }
    for (key, value) in std::env::vars() {
        if key.contains('\x1e') || key.contains('\x1f') || value.contains('\x1e') || value.contains('\x1f') {
            continue;
        }
        fields.push(("env".into(), format!("{key}={value}")));
    }
    if send(&mut stream, HELLO, &encode(&fields)).is_err() {
        return 1;
    }

    let _raw = RawMode::enter();
    // Keys to the session.
    {
        let mut writer = stream.try_clone().expect("socket");
        thread::spawn(move || {
            let mut buffer = [0u8; 16384];
            let mut stdin = std::io::stdin();
            loop {
                match stdin.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if send(&mut writer, INPUT, &buffer[..n]).is_err() {
                            break;
                        }
                    }
                }
            }
        });
    }
    // The terminal's size, when it changes.
    {
        let mut writer = stream.try_clone().expect("socket");
        thread::spawn(move || {
            let mut last = window_size();
            loop {
                thread::sleep(Duration::from_millis(200));
                let now = window_size();
                if now != last {
                    last = now;
                    let mut payload = now.0.to_be_bytes().to_vec();
                    payload.extend_from_slice(&now.1.to_be_bytes());
                    if send(&mut writer, RESIZE, &payload).is_err() {
                        break;
                    }
                }
            }
        });
    }
    // Its output to the terminal, until it ends.
    let mut stdout = std::io::stdout();
    loop {
        match receive(&mut stream) {
            Ok((OUTPUT, bytes)) => {
                let _ = stdout.write_all(&bytes);
                let _ = stdout.flush();
            }
            Ok((EXIT, code)) if code.len() == 4 => return i32::from_be_bytes([code[0], code[1], code[2], code[3]]),
            Ok((INFO, text)) if text == b"attached elsewhere" => return 0,
            Ok((INFO, text)) => {
                let _ = stdout.write_all(b"\r\nmuxyd: ");
                let _ = stdout.write_all(&text);
                let _ = stdout.write_all(b"\r\n");
            }
            Ok(_) => {}
            Err(_) => return 1,
        }
    }
}

/// A program name as the shell would find it on PATH.
fn resolve(program: &str) -> String {
    if program.contains('/') {
        return program.to_string();
    }
    let path = std::env::var("PATH").unwrap_or_default();
    for dir in path.split(':') {
        let candidate = Path::new(dir).join(program);
        if candidate.is_file() {
            return candidate.to_string_lossy().to_string();
        }
    }
    program.to_string()
}

fn kill(socket: &Path, args: &[String]) -> i32 {
    let Some(id) = option(args, "--id") else { return 2 };
    let Ok(mut stream) = UnixStream::connect(socket) else { return 0 };
    let _ = send(&mut stream, KILL, id.as_bytes());
    let _ = receive(&mut stream);
    0
}

fn list(socket: &Path) -> i32 {
    let Ok(mut stream) = UnixStream::connect(socket) else { return 0 };
    let _ = send(&mut stream, LIST, b"");
    if let Ok((INFO, text)) = receive(&mut stream) {
        println!("{}", String::from_utf8_lossy(&text));
    }
    0
}
