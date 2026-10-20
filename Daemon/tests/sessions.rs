//! The daemon as muxy uses it: real processes, a real socket, clients that
//! come and go.

use std::io::Read;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

fn muxyd() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_muxyd"))
}

fn socket(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("muxyd-test-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("s.sock")
}

fn attach(socket: &PathBuf, id: &str, program: &[&str]) -> Child {
    let mut command = Command::new(muxyd());
    command.args(["attach", "--socket"]).arg(socket).args(["--id", id]);
    if !program.is_empty() {
        command.arg("--").args(program);
    }
    command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).spawn().unwrap()
}

/// Everything the client prints, as it comes.
fn output(child: &mut Child) -> mpsc::Receiver<String> {
    let mut stdout = child.stdout.take().unwrap();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let mut buffer = [0u8; 4096];
        while let Ok(n) = stdout.read(&mut buffer) {
            if n == 0 {
                break;
            }
            let _ = tx.send(String::from_utf8_lossy(&buffer[..n]).to_string());
        }
    });
    rx
}

fn wait_for(rx: &mpsc::Receiver<String>, text: &str, seen: &mut String, within: Duration) -> bool {
    let end = Instant::now() + within;
    while Instant::now() < end {
        if seen.contains(text) {
            return true;
        }
        if let Ok(chunk) = rx.recv_timeout(Duration::from_millis(100)) {
            seen.push_str(&chunk);
        }
    }
    seen.contains(text)
}

fn list(socket: &PathBuf) -> String {
    let out = Command::new(muxyd()).args(["list", "--socket"]).arg(socket).output().unwrap();
    String::from_utf8_lossy(&out.stdout).to_string()
}

#[test]
fn a_session_outlives_its_client_and_the_next_one_gets_what_it_missed() {
    let socket = socket("outlives");
    let mut first = attach(&socket, "agent", &["/bin/sh", "-c", "echo started; sleep 2; echo while-you-were-away; sleep 1; echo done; exit 7"]);
    let rx = output(&mut first);
    let mut seen = String::new();
    assert!(wait_for(&rx, "started", &mut seen, Duration::from_secs(5)), "got: {seen}");

    // muxy quits: its terminal and the client in it go away.
    first.kill().unwrap();
    first.wait().unwrap();
    assert!(list(&socket).contains("agent"), "the program still runs");

    thread::sleep(Duration::from_millis(2500));
    let mut second = attach(&socket, "agent", &[]);
    let rx = output(&mut second);
    let mut seen = String::new();
    assert!(wait_for(&rx, "while-you-were-away", &mut seen, Duration::from_secs(5)), "missed output replayed: {seen}");
    assert!(wait_for(&rx, "done", &mut seen, Duration::from_secs(5)), "and it goes on: {seen}");
    let status = second.wait().unwrap();
    assert_eq!(status.code(), Some(7), "its exit status reaches the client");
    assert!(!list(&socket).contains("agent"), "an ended program is no session");
}

#[test]
fn kill_ends_a_session_for_good() {
    let socket = socket("kill");
    let mut client = attach(&socket, "shell", &["/bin/sh", "-c", "echo ready; sleep 100"]);
    let rx = output(&mut client);
    let mut seen = String::new();
    assert!(wait_for(&rx, "ready", &mut seen, Duration::from_secs(5)));
    let start = Instant::now();
    Command::new(muxyd()).args(["kill", "--socket"]).arg(&socket).args(["--id", "shell"]).status().unwrap();
    let status = client.wait().unwrap();
    assert!(start.elapsed() < Duration::from_secs(5), "ends promptly");
    assert_ne!(status.code(), Some(0));
    assert!(!list(&socket).contains("shell"));
}

#[test]
fn keys_reach_the_program() {
    use std::io::Write;
    let socket = socket("keys");
    let mut client = attach(&socket, "cat", &["/bin/sh", "-c", "read line; echo \"got:$line\""]);
    let rx = output(&mut client);
    thread::sleep(Duration::from_millis(500));
    client.stdin.as_mut().unwrap().write_all(b"hello\r").unwrap();
    let mut seen = String::new();
    assert!(wait_for(&rx, "got:hello", &mut seen, Duration::from_secs(5)), "got: {seen}");
    assert_eq!(client.wait().unwrap().code(), Some(0));
}

#[test]
fn the_program_gets_the_clients_environment_and_folder() {
    let socket = socket("env");
    let mut command = Command::new(muxyd());
    command.args(["attach", "--socket"]).arg(&socket).args(["--id", "env", "--cwd", "/tmp", "--", "/bin/sh", "-c", "echo \"$MUXY_SESSION in $(pwd)\""]);
    let mut client = command.env("MUXY_SESSION", "s-42").stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    let rx = output(&mut client);
    let mut seen = String::new();
    assert!(wait_for(&rx, "s-42 in /private/tmp", &mut seen, Duration::from_secs(5)) || seen.contains("s-42 in /tmp"), "got: {seen}");
    client.wait().unwrap();
}
