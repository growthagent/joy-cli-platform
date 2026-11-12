//! What scripts/test.roc needs and basic-cli has no API for.
//!
//! - `terminal [options] -- program args...` runs a program on a terminal of
//!   its own: a pseudo-terminal on Unix, a hidden console on Windows. It types
//!   the input, can send a signal, checks that the terminal mode is put back
//!   once the program has exited, and prints the outcome as JSON.
//! - `detached -- program args...` runs a program with no controlling
//!   terminal or console, with this process's standard streams. On Unix the
//!   helper becomes the program, on Windows it exits as the program did.
//! - `serve DIR` serves the files directly in DIR over HTTP on a free port of
//!   127.0.0.1 and prints the base URL on its first line.
//! - `emit [--stdout LINE] [--stderr LINE] [--exit CODE]` prints each line to
//!   its stream, in order, and exits with the code: a command the spec can
//!   run on every OS.
//!
//! The JSON of `terminal` always has the keys `exit_code`, `output` and
//! `error`. Either `error` is null, or the other two are.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

#[cfg(unix)]
mod unix;
#[cfg(windows)]
mod windows;

/// One run of a program on a terminal.
#[derive(Debug, Clone, PartialEq)]
pub struct Request {
    pub timeout: f64,
    pub input_delay: f64,
    pub stdin: Vec<u8>,
    pub await_raw_mode: bool,
    pub await_output: Option<String>,
    pub send_signal: Option<String>,
    pub args: Vec<String>,
}

/// How a run ended, or why it could not be judged.
pub type Outcome = Result<(i64, String), String>;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.split_first() {
        Some((command, rest)) if command == "terminal" => match parse_request(rest) {
            Ok(request) => {
                println!("{}", run_terminal(&request));
                ExitCode::SUCCESS
            }
            Err(message) => usage(&message),
        },
        #[cfg(windows)]
        Some((command, rest)) if command == "console-inner" => windows::inner(rest),
        Some((command, rest)) if command == "detached" => match rest.split_first() {
            Some((dashes, program)) if dashes == "--" && !program.is_empty() => detached(program),
            _ => usage("detached needs -- and a program"),
        },
        Some((command, rest)) if command == "serve" && rest.len() == 1 => serve(Path::new(&rest[0])),
        Some((command, rest)) if command == "emit" => emit(rest),
        _ => usage("unknown command"),
    }
}

fn usage(message: &str) -> ExitCode {
    eprintln!("test-helper: {message}");
    eprintln!("usage: test-helper terminal [--timeout S] [--input-delay S] [--stdin-hex HEX] [--await-raw-mode] [--await-output TEXT] [--send-signal NAME] -- program args...");
    eprintln!("       test-helper detached -- program args...");
    eprintln!("       test-helper serve DIR");
    eprintln!("       test-helper emit [--stdout LINE] [--stderr LINE] [--exit CODE]");
    ExitCode::from(2)
}

/// The outcome as JSON.
#[cfg(unix)]
fn run_terminal(request: &Request) -> String {
    outcome_json(&unix::run(request))
}

/// The outcome as JSON, as the helper in the hidden console wrote it.
#[cfg(windows)]
fn run_terminal(request: &Request) -> String {
    windows::run(request).unwrap_or_else(|error| outcome_json(&Err(error)))
}

/// The options of `terminal`, then `--` and the program to run.
pub fn parse_request(args: &[String]) -> Result<Request, String> {
    let mut request = Request {
        timeout: 7.0,
        input_delay: 0.08,
        stdin: Vec::new(),
        await_raw_mode: false,
        await_output: None,
        send_signal: None,
        args: Vec::new(),
    };
    let mut rest = args.iter();
    while let Some(arg) = rest.next() {
        let mut value = |name: &str| rest.next().cloned().ok_or(format!("{name} needs a value"));
        match arg.as_str() {
            "--timeout" => request.timeout = seconds(&value("--timeout")?)?,
            "--input-delay" => request.input_delay = seconds(&value("--input-delay")?)?,
            "--stdin-hex" => request.stdin = from_hex(&value("--stdin-hex")?)?,
            "--await-raw-mode" => request.await_raw_mode = true,
            "--await-output" => request.await_output = Some(value("--await-output")?),
            "--send-signal" => request.send_signal = Some(value("--send-signal")?),
            "--" => {
                request.args = rest.cloned().collect();
                break;
            }
            other => return Err(format!("unknown option {other}")),
        }
    }
    if request.args.is_empty() {
        return Err("no program to run".into());
    }
    Ok(request)
}

fn seconds(text: &str) -> Result<f64, String> {
    match text.parse::<f64>() {
        Ok(value) if value.is_finite() && value >= 0.0 => Ok(value),
        _ => Err(format!("not a number of seconds: {text}")),
    }
}

fn from_hex(text: &str) -> Result<Vec<u8>, String> {
    let digits = text.as_bytes();
    if !digits.len().is_multiple_of(2) {
        return Err(format!("odd number of hex digits: {text}"));
    }
    digits
        .chunks(2)
        .map(|pair| {
            std::str::from_utf8(pair)
                .ok()
                .and_then(|pair| u8::from_str_radix(pair, 16).ok())
                .ok_or(format!("not hex: {text}"))
        })
        .collect()
}

pub fn outcome_json(outcome: &Outcome) -> String {
    match outcome {
        Ok((exit_code, output)) => {
            format!("{{\"exit_code\":{exit_code},\"output\":{},\"error\":null}}", json_string(output))
        }
        Err(error) => format!("{{\"exit_code\":null,\"output\":null,\"error\":{}}}", json_string(error)),
    }
}

fn json_string(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for c in text.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

/// Sleeps for a number of seconds.
pub fn sleep_seconds(seconds: f64) {
    std::thread::sleep(Duration::from_secs_f64(seconds));
}

/// Leaves the controlling terminal for a session of its own, then becomes
/// the program. The program keeps this process's id, so whoever started the
/// helper waits for, times out and stops the program itself.
#[cfg(unix)]
fn detached(program: &[String]) -> ExitCode {
    use std::os::unix::process::CommandExt;
    // The helper was started as a child, which is never a process group
    // leader, so setsid succeeds.
    if unsafe { libc::setsid() } == -1 {
        eprintln!("test-helper: setsid: {}", std::io::Error::last_os_error());
        return ExitCode::from(127);
    }
    let error = std::process::Command::new(&program[0]).args(&program[1..]).exec();
    eprintln!("test-helper: could not start {}: {error}", program[0]);
    ExitCode::from(127)
}

#[cfg(windows)]
fn detached(program: &[String]) -> ExitCode {
    use std::os::windows::process::CommandExt;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    let status = std::process::Command::new(&program[0])
        .args(&program[1..])
        .creation_flags(DETACHED_PROCESS)
        .status();
    match status {
        Ok(status) => windows::exit_with(status.code().unwrap_or(1)),
        Err(error) => {
            eprintln!("test-helper: could not start {}: {error}", program[0]);
            ExitCode::from(127)
        }
    }
}

fn emit(args: &[String]) -> ExitCode {
    let mut code = 0;
    let mut rest = args.iter();
    while let Some(option) = rest.next() {
        let Some(value) = rest.next() else {
            return usage(&format!("{option} needs a value"));
        };
        match option.as_str() {
            "--stdout" => {
                println!("{value}");
                let _ = std::io::stdout().flush();
            }
            "--stderr" => eprintln!("{value}"),
            "--exit" => match value.parse::<u8>() {
                Ok(value) => code = value,
                Err(_) => return usage(&format!("not an exit code: {value}")),
            },
            _ => return usage(&format!("unknown option {option}")),
        }
    }
    ExitCode::from(code)
}

fn serve(dir: &Path) -> ExitCode {
    let dir = match dir.canonicalize() {
        Ok(dir) if dir.is_dir() => dir,
        _ => return usage(&format!("not a directory: {}", dir.display())),
    };
    let listener = match TcpListener::bind("127.0.0.1:0") {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("test-helper: could not listen: {error}");
            return ExitCode::FAILURE;
        }
    };
    let port = listener.local_addr().map(|address| address.port()).unwrap_or(0);
    println!("http://127.0.0.1:{port}");
    let _ = std::io::stdout().flush();
    for stream in listener.incoming().flatten() {
        let dir = dir.clone();
        std::thread::spawn(move || {
            let _ = answer(stream, &dir);
        });
    }
    ExitCode::SUCCESS
}

/// Answers one HTTP request for a file directly in `dir`, then closes.
fn answer(mut stream: TcpStream, dir: &Path) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;
    loop {
        let mut header = String::new();
        if reader.read_line(&mut header)? == 0 || header.trim().is_empty() {
            break;
        }
    }
    let mut words = request_line.split_whitespace();
    let method = words.next().unwrap_or("");
    let target = words.next().unwrap_or("");
    let name = target.split(['?', '#']).next().unwrap_or("").trim_start_matches('/');
    if method != "GET" && method != "HEAD" {
        return respond(&mut stream, "405 Method Not Allowed", None, method);
    }
    let file = file_in(dir, name);
    match file.as_ref().map(std::fs::read) {
        Some(Ok(bytes)) => respond(&mut stream, "200 OK", Some(bytes), method),
        _ => respond(&mut stream, "404 Not Found", None, method),
    }
}

/// A file directly in `dir`, never one elsewhere.
fn file_in(dir: &Path, name: &str) -> Option<PathBuf> {
    let plain = !name.is_empty() && name != "." && name != ".." && !name.contains(['/', '\\', ':']);
    let path = dir.join(name);
    (plain && path.is_file()).then_some(path)
}

fn respond(stream: &mut TcpStream, status: &str, body: Option<Vec<u8>>, method: &str) -> std::io::Result<()> {
    let body = body.unwrap_or_else(|| status.as_bytes().to_vec());
    write!(
        stream,
        "HTTP/1.0 {status}\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )?;
    if method != "HEAD" {
        stream.write_all(&body)?;
    }
    stream.flush()?;
    // Read what the client may still send, so closing does not reset the
    // connection before it has read the answer.
    let _ = stream.shutdown(std::net::Shutdown::Write);
    let mut rest = [0u8; 1024];
    let _ = stream.set_read_timeout(Some(Duration::from_secs(1)));
    while matches!(stream.read(&mut rest), Ok(n) if n > 0) {}
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| word.to_string()).collect()
    }

    #[test]
    fn parses_a_request() {
        let request = parse_request(&strings(&[
            "--timeout", "20", "--stdin-hex", "710a", "--await-raw-mode", "--send-signal", "SIGTERM", "--", "app", "--flag",
        ]))
        .unwrap();
        assert_eq!(request.timeout, 20.0);
        assert_eq!(request.input_delay, 0.08);
        assert_eq!(request.stdin, b"q\n");
        assert!(request.await_raw_mode);
        assert_eq!(request.send_signal.as_deref(), Some("SIGTERM"));
        assert_eq!(request.args, strings(&["app", "--flag"]));
    }

    #[test]
    fn refuses_a_request_without_a_program() {
        assert!(parse_request(&strings(&["--timeout", "1"])).is_err());
        assert!(parse_request(&strings(&["--stdin-hex", "7", "--", "app"])).is_err());
    }

    #[test]
    fn writes_json() {
        assert_eq!(
            outcome_json(&Ok((-15, "a\"b\\\n\u{1}".into()))),
            "{\"exit_code\":-15,\"output\":\"a\\\"b\\\\\\n\\u0001\",\"error\":null}"
        );
        assert_eq!(outcome_json(&Err("no".into())), "{\"exit_code\":null,\"output\":null,\"error\":\"no\"}");
    }

    #[test]
    fn serves_only_files_directly_in_the_folder() {
        let dir = std::env::temp_dir();
        assert_eq!(file_in(&dir, ".."), None);
        assert_eq!(file_in(&dir, "../etc/passwd"), None);
        assert_eq!(file_in(&dir, ""), None);
    }
}
