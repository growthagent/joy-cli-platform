//! A program on a pseudo-terminal of its own.

use crate::{sleep_seconds, Outcome, Request};
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::ExitStatusExt;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// The parts of a terminal mode that a program can change.
#[derive(Debug, Clone, PartialEq)]
struct Mode {
    iflag: libc::tcflag_t,
    oflag: libc::tcflag_t,
    cflag: libc::tcflag_t,
    lflag: libc::tcflag_t,
    ispeed: libc::speed_t,
    ospeed: libc::speed_t,
    cc: Vec<libc::cc_t>,
}

struct Pty {
    master: RawFd,
    slave: RawFd,
}

impl Drop for Pty {
    fn drop(&mut self) {
        unsafe {
            libc::close(self.slave);
            libc::close(self.master);
        }
    }
}

fn os_error(what: &str) -> String {
    format!("{what}: {}", std::io::Error::last_os_error())
}

fn cloexec(fd: RawFd) {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC);
    }
}

impl Pty {
    fn open() -> Result<Pty, String> {
        unsafe {
            let master = libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY);
            if master < 0 {
                return Err(os_error("posix_openpt"));
            }
            cloexec(master);
            if libc::grantpt(master) != 0 || libc::unlockpt(master) != 0 {
                let error = os_error("grantpt");
                libc::close(master);
                return Err(error);
            }
            let name = libc::ptsname(master);
            if name.is_null() {
                let error = os_error("ptsname");
                libc::close(master);
                return Err(error);
            }
            let slave = libc::open(name, libc::O_RDWR | libc::O_NOCTTY);
            if slave < 0 {
                let error = os_error("open the terminal");
                libc::close(master);
                return Err(error);
            }
            cloexec(slave);
            let pty = Pty { master, slave };
            // A size, so `Tty.size!` has something to report: 24 rows of 80 columns.
            let size = libc::winsize { ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0 };
            if libc::ioctl(slave, libc::TIOCSWINSZ, &size) != 0 {
                return Err(os_error("TIOCSWINSZ"));
            }
            Ok(pty)
        }
    }

    fn mode(&self) -> Result<Mode, String> {
        unsafe {
            let mut termios: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(self.slave, &mut termios) != 0 {
                return Err(os_error("tcgetattr"));
            }
            Ok(Mode {
                iflag: termios.c_iflag,
                oflag: termios.c_oflag,
                cflag: termios.c_cflag,
                // BSD kernels set PENDIN themselves when a terminal returns to
                // line mode, and only clear it on the next read. It is not
                // part of the requested mode.
                lflag: termios.c_lflag & !libc::PENDIN,
                ispeed: libc::cfgetispeed(&termios),
                ospeed: libc::cfgetospeed(&termios),
                cc: termios.c_cc.to_vec(),
            })
        }
    }

    fn slave_stdio(&self) -> Result<Stdio, String> {
        let fd = unsafe { libc::dup(self.slave) };
        if fd < 0 {
            return Err(os_error("dup"));
        }
        Ok(Stdio::from(unsafe { OwnedFd::from_raw_fd(fd) }))
    }

    /// Waits up to `timeout` for output, and reads what there is. `None` at
    /// the end of the output.
    fn read(&self, timeout: Duration) -> Option<Vec<u8>> {
        let mut poll = libc::pollfd { fd: self.master, events: libc::POLLIN, revents: 0 };
        let ready = unsafe { libc::poll(&mut poll, 1, timeout.as_millis() as libc::c_int) };
        if ready <= 0 {
            return Some(Vec::new());
        }
        let mut buffer = vec![0u8; 65536];
        let count = unsafe { libc::read(self.master, buffer.as_mut_ptr().cast(), buffer.len()) };
        if count <= 0 {
            return None;
        }
        buffer.truncate(count as usize);
        Some(buffer)
    }

    fn write(&self, bytes: &[u8]) -> Result<(), String> {
        let count = unsafe { libc::write(self.master, bytes.as_ptr().cast(), bytes.len()) };
        if count as usize != bytes.len() {
            return Err(os_error("write to the terminal"));
        }
        Ok(())
    }
}

fn signal_number(name: &str) -> Option<libc::c_int> {
    Some(match name {
        "SIGHUP" => libc::SIGHUP,
        "SIGINT" => libc::SIGINT,
        "SIGQUIT" => libc::SIGQUIT,
        "SIGKILL" => libc::SIGKILL,
        "SIGTERM" => libc::SIGTERM,
        "SIGUSR1" => libc::SIGUSR1,
        "SIGUSR2" => libc::SIGUSR2,
        "SIGWINCH" => libc::SIGWINCH,
        _ => return None,
    })
}

fn has_exited(child: &mut Child) -> bool {
    !matches!(child.try_wait(), Ok(None))
}

pub fn run(request: &Request) -> Outcome {
    let signal = match &request.send_signal {
        Some(name) => Some(signal_number(name).ok_or(format!("Unknown signal {name}"))?),
        None => None,
    };
    let pty = Pty::open()?;
    // The slave stays open so the terminal mode can be read after the child exits.
    let initial_mode = pty.mode()?;
    let mut child = Command::new(&request.args[0])
        .args(&request.args[1..])
        .stdin(pty.slave_stdio()?)
        .stdout(pty.slave_stdio()?)
        .stderr(pty.slave_stdio()?)
        .spawn()
        .map_err(|error| format!("could not start {}: {error}", request.args[0]))?;
    let result = drive(request, &pty, &initial_mode, &mut child, signal);
    if !has_exited(&mut child) {
        let _ = child.kill();
        let _ = child.wait();
    }
    result
}

fn drive(request: &Request, pty: &Pty, initial_mode: &Mode, child: &mut Child, signal: Option<libc::c_int>) -> Outcome {
    let started = Instant::now();
    let deadline = started + Duration::from_secs_f64(request.timeout);
    let mut output = Vec::new();
    if request.await_raw_mode {
        while pty.mode()? == *initial_mode {
            if has_exited(child) || Instant::now() >= deadline {
                return Err("Terminal never changed mode".into());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    } else if let Some(expected) = &request.await_output {
        // A fixed wait loses to a slow start, such as macOS checking a binary
        // on its first launch.
        while !contains(&output, expected.as_bytes()) {
            if has_exited(child) || Instant::now() >= deadline {
                return Err(format!("Never printed {expected:?}"));
            }
            if let Some(chunk) = pty.read(Duration::from_millis(10)) {
                output.extend(chunk);
            }
        }
    } else {
        sleep_seconds(0.25);
    }
    for byte in &request.stdin {
        pty.write(&[*byte])?;
        sleep_seconds(request.input_delay);
    }
    if let Some(signal) = signal {
        unsafe {
            libc::kill(child.id() as libc::pid_t, signal);
        }
    }
    let status = loop {
        if let Ok(Some(status)) = child.try_wait() {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("Timed out after {}s", request.timeout));
        }
        match pty.read(Duration::from_millis(100)) {
            Some(chunk) => output.extend(chunk),
            None => break child.wait().map_err(|error| format!("wait: {error}"))?,
        }
    };
    // What the program wrote before it exited.
    while let Some(chunk) = pty.read(Duration::ZERO) {
        if chunk.is_empty() {
            break;
        }
        output.extend(chunk);
    }
    let final_mode = pty.mode()?;
    if final_mode != *initial_mode {
        return Err(format!("Terminal mode was not restored (before: {initial_mode:?}, after: {final_mode:?})"));
    }
    let exit_code = match status.signal() {
        Some(signal) => -(signal as i64),
        None => status.code().unwrap_or(-1) as i64,
    };
    Ok((exit_code, String::from_utf8_lossy(&output).into_owned()))
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    needle.is_empty() || haystack.windows(needle.len()).any(|window| window == needle)
}
