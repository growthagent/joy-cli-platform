//! The Unix leash: a forked watchdog that takes a managed child's whole
//! process group down when this host process dies, however it dies.
//!
//! `Cmd.spawn_leashed!` asks for this. The child is placed in the group the
//! watchdog leads (see [`crate::process_service`]), so three things stop a
//! leashed child from outliving the host: the normal-exit sweep in
//! `process_service::shutdown`, this watchdog on deaths that skip it (Ctrl+C,
//! crashes, `kill -9`), and on Linux also `PR_SET_PDEATHSIG`, which needs no
//! second process and fires without the watchdog's EOF latency.
//!
//! Windows needs none of this: a managed child there lives in a Job Object
//! with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so the OS takes the job down
//! when the host's handle closes, on any death. This module is Unix-only.
#![cfg(unix)]

use std::io;

/// Takes a leashed child's whole process group down when this process dies,
/// however it dies. A forked helper leads the group and blocks reading a pipe
/// whose write end lives only in this process, so any death of this process
/// closes the pipe, the read returns EOF, and the helper SIGKILLs the group.
/// This is what cleans up after Ctrl+C, crashes, and `kill -9`, none of which
/// run the exit sweep on normal return. Linux additionally has PDEATHSIG, but
/// that covers only the direct child, while the group kill here also reaps
/// grandchildren.
///
/// The helper forks before the child spawns and founds the group itself, so
/// the group provably exists by the time the child joins it, and the pgid is
/// pinned against reuse for exactly as long as the leash is held. The helper
/// execs nothing (no /bin/sh required on the system, so this works in
/// scratch containers) and blocks every signal, so nothing short of SIGKILL
/// can strip the leash.
///
/// The liveness pipe is deliberately separate from the child's stdin. Closing
/// a child's stdin is the normal way to signal end of input and must not read
/// as a death sentence.
pub(crate) struct Watchdog {
    /// The helper's pid, which is also the pgid of the group it leads.
    pgid: libc::pid_t,
    /// Closing this is what wakes the watchdog, see Drop.
    liveness: Option<io::PipeWriter>,
}

impl Watchdog {
    /// The process group id the child should join, i.e. the helper's pid.
    pub(crate) fn pgid(&self) -> libc::pid_t {
        self.pgid
    }

    /// A watchdog that fails to fork is reported as None rather than as a
    /// spawn failure: the child still spawns, leading its own group, which is
    /// the behavior all leashed children had before watchdogs existed.
    pub(crate) fn fork() -> Option<Watchdog> {
        use std::os::fd::AsRawFd;
        let (reader, writer) = io::pipe().ok()?;
        // The helper's fd sweep bound has to be taken on this side of the
        // fork: getrlimit is not on the async-signal-safe list.
        let fd_limit = fd_sweep_limit();
        match unsafe { libc::fork() } {
            -1 => None,
            0 => unsafe { watchdog_main(reader.as_raw_fd(), fd_limit) },
            helper => {
                let watchdog = Watchdog {
                    pgid: helper,
                    liveness: Some(writer),
                };
                // Found the group from this side as well: the helper's own
                // setpgid may not have run yet, and the child joins the group
                // as soon as this returns. setpgid on a forked child that has
                // not exec'd cannot fail with EACCES, which is what makes the
                // group's existence deterministic rather than a race.
                if unsafe { libc::setpgid(helper, helper) } == 0 {
                    Some(watchdog)
                } else {
                    // Dropping the watchdog wakes and reaps the helper.
                    None
                }
            }
        }
    }
}

/// The body of the forked watchdog helper.
///
/// SAFETY FENCE: this runs in the child of a fork from a multithreaded
/// process, where POSIX allows only async-signal-safe operations until
/// _exit. Everything in here must stay raw libc: no allocation, no locks, no
/// panics, no Rust std I/O. (`io::Error::last_os_error().raw_os_error()` is
/// fine, it only reads errno.)
unsafe fn watchdog_main(liveness_fd: libc::c_int, fd_limit: libc::c_int) -> ! {
    // Block everything blockable, and do it first: handlers inherited from
    // the host can never run in here, and stray signals to the group cannot
    // quietly kill the watchdog and strip the leash. The order matters to
    // the tests: macOS has no way to read another process's signal mask, so
    // there they take "the fd sweep has finished" as the proof that the mask
    // is up, which only holds because the mask always comes first. It delays
    // the sweep by exactly one syscall.
    let mut all: libc::sigset_t = std::mem::zeroed();
    libc::sigfillset(&mut all);
    libc::sigprocmask(libc::SIG_BLOCK, &all, std::ptr::null_mut());

    // Keep only the liveness read end. fork duplicated every one of the
    // host's fds into this helper, and until they are closed this process
    // holds them open: a listening socket held open here is observable to
    // the rest of the host (a just-closed port would not be free to rebind),
    // so nothing that could wait runs before the sweep. The sweep also drops
    // the write ends of sibling watchdogs, which would otherwise never reach
    // EOF while this helper lives, and the host's own stdio pipes.
    libc::dup2(liveness_fd, 0);
    close_fds_from(1, fd_limit);

    // Found the group. The parent does this too, whoever runs first wins.
    libc::setpgid(0, 0);

    // Nothing is ever written to the pipe, so the only successful read is
    // EOF, and it means the sole holder of the write end, the host process,
    // is gone. Signals are blocked, but stay robust against EINTR anyway.
    let mut byte = 0u8;
    loop {
        let n = libc::read(0, &mut byte as *mut u8 as *mut libc::c_void, 1);
        if n >= 0 || io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            break;
        }
    }

    // Nuke the group, but only if this helper actually leads it: killing by
    // explicit pgid (never kill(0)) cannot hit the host's own group through
    // some earlier setpgid failure.
    let own_pid = libc::getpid();
    if libc::getpgrp() == own_pid {
        libc::kill(-own_pid, libc::SIGKILL);
    }
    libc::_exit(0)
}

/// Close every fd in [first, limit) inside the forked helper. Only
/// async-signal-safe calls, see the fence on watchdog_main.
unsafe fn close_fds_from(first: libc::c_int, limit: libc::c_int) {
    // One syscall on Linux 5.9+. The loop covers older kernels and the
    // Unixes without close_range (macOS).
    #[cfg(target_os = "linux")]
    if libc::syscall(
        libc::SYS_close_range,
        first as libc::c_uint,
        libc::c_uint::MAX,
        0 as libc::c_uint,
    ) == 0
    {
        return;
    }
    close_fds_loop(first, limit);
}

/// The fallback sweep for platforms without close_range. Factored out so the
/// tests can exercise it on Linux, where close_range normally shadows it.
/// Async-signal-safe.
unsafe fn close_fds_loop(first: libc::c_int, limit: libc::c_int) {
    for fd in first..limit {
        libc::close(fd);
    }
}

/// Upper bound for the helper's fd sweep: fd numbers are capped by the soft
/// NOFILE limit. Clamped in case the limit is set to unlimited.
fn fd_sweep_limit() -> libc::c_int {
    let mut rl = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    let soft = if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut rl) } == 0 {
        rl.rlim_cur
    } else {
        1024
    };
    soft.min(1 << 20) as libc::c_int
}

impl Drop for Watchdog {
    fn drop(&mut self) {
        // Dropping the write end wakes the watchdog, which group-kills any
        // stragglers (the child itself is dead or already being killed
        // whenever its managed child is dropped) and dies with them, being in
        // the same group. The wait is bounded by that and keeps the helper
        // from lingering as a zombie. A helper already reaped elsewhere (the
        // managed child's own group reap) makes waitpid return ECHILD, which
        // is not EINTR, so the loop exits at once.
        self.liveness.take();
        let mut status: libc::c_int = 0;
        while unsafe { libc::waitpid(self.pgid, &mut status, 0) } == -1
            && io::Error::last_os_error().raw_os_error() == Some(libc::EINTR)
        {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as _;
    use std::os::unix::process::ExitStatusExt as _;
    use std::process::Stdio;
    use std::thread;
    use std::time::Duration;

    /// Fork a watchdog and spawn `cmd` into the group it leads, exactly as
    /// `process_service` does for a leashed child, minus the stdio plumbing.
    /// Shared by the tests so they drive the real leash path.
    fn leash_spawn(
        cmd: &mut std::process::Command,
    ) -> io::Result<(std::process::Child, libc::pid_t, Option<Watchdog>)> {
        use std::os::unix::process::CommandExt;

        // The watchdog forks first and founds the group, so the group already
        // exists when the child joins it: no retry loop, and no window in
        // which the child runs without its leash pinned. When the fork failed
        // the child leads its own group, unleashed.
        let watchdog = Watchdog::fork();
        cmd.process_group(watchdog.as_ref().map_or(0, |w| w.pgid));
        let child = cmd.spawn()?;
        let pgid = watchdog
            .as_ref()
            .map_or(child.id() as libc::pid_t, |w| w.pgid);
        Ok((child, pgid, watchdog))
    }

    /// Polls until `pid` no longer exists. Zombies still "exist" for
    /// kill(0), so for another process's orphans this also waits out the
    /// reparent-to-init and reap that follows their parent's death.
    fn wait_until_gone(pid: libc::pid_t) {
        for _ in 0..1000 {
            if unsafe { libc::kill(pid, 0) } == -1 {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("process {pid} still alive after 10s");
    }

    fn sleeper() -> std::process::Command {
        let mut cmd = std::process::Command::new("sleep");
        cmd.arg("600");
        cmd
    }

    #[test]
    fn dropping_the_watchdog_takes_the_group_down() {
        let (mut child, pgid, watchdog) = leash_spawn(&mut sleeper()).unwrap();
        let watchdog = watchdog.expect("watchdog fork failed");
        assert_eq!(pgid, watchdog.pgid);
        drop(watchdog);
        let status = child.wait().unwrap();
        assert_eq!(status.signal(), Some(libc::SIGKILL));
        wait_until_gone(pgid);
    }

    #[test]
    fn the_pgid_stays_pinned_after_the_child_exits() {
        let mut cmd = std::process::Command::new("true");
        let (mut child, pgid, watchdog) = leash_spawn(&mut cmd).unwrap();
        assert!(watchdog.is_some(), "watchdog fork failed");
        child.wait().unwrap();
        // The group must survive its founding child: the helper holds it, so
        // an exit-time kill(-pgid) can never hit a recycled group.
        assert_eq!(
            unsafe { libc::kill(-pgid, 0) },
            0,
            "group vanished with the child"
        );
        drop(watchdog);
        wait_until_gone(pgid);
    }

    /// The helper's open fds in ascending order, or None while it cannot be
    /// inspected. From /proc on Linux, from libproc elsewhere.
    #[cfg(target_os = "linux")]
    fn helper_open_fds(pid: libc::pid_t) -> Option<Vec<i32>> {
        let entries = std::fs::read_dir(format!("/proc/{pid}/fd")).ok()?;
        let mut fds: Vec<i32> = entries
            .filter_map(|entry| entry.ok()?.file_name().to_str()?.parse().ok())
            .collect();
        fds.sort_unstable();
        Some(fds)
    }

    #[cfg(not(target_os = "linux"))]
    fn helper_open_fds(pid: libc::pid_t) -> Option<Vec<i32>> {
        let mut fds = [libc::proc_fdinfo {
            proc_fd: 0,
            proc_fdtype: 0,
        }; 256];
        let entry = std::mem::size_of::<libc::proc_fdinfo>();
        let bytes = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDLISTFDS,
                0,
                fds.as_mut_ptr().cast(),
                (fds.len() * entry) as libc::c_int,
            )
        };
        if bytes <= 0 {
            return None;
        }
        // A helper still holding more fds than fit is reported truncated,
        // which is never [0], so callers keep polling.
        let count = (bytes as usize / entry).min(fds.len());
        let mut fds: Vec<i32> = fds[..count].iter().map(|info| info.proc_fd).collect();
        fds.sort_unstable();
        Some(fds)
    }

    /// Two leashes: the second helper forks while the first one's liveness
    /// write end is open in this process, so only the fd sweep keeps it from
    /// holding that write end and stalling the first leash's EOF. This is
    /// the close_range-less loop on macOS, so it matters most there.
    #[test]
    fn the_helper_keeps_only_its_liveness_fd() {
        let (mut child_a, _pgid_a, watchdog_a) = leash_spawn(&mut sleeper()).unwrap();
        let (mut child_b, pgid_b, watchdog_b) = leash_spawn(&mut sleeper()).unwrap();
        assert!(watchdog_b.is_some(), "watchdog fork failed");
        let mut fds = None;
        for _ in 0..1000 {
            fds = helper_open_fds(pgid_b);
            if fds.as_deref() == Some(&[0]) {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            fds.as_deref(),
            Some(&[0][..]),
            "helper still holds inherited fds"
        );
        drop(watchdog_a);
        drop(watchdog_b);
        let _ = child_a.wait();
        let _ = child_b.wait();
    }

    /// Parses the fake host's stdout for the tree it leashed: pgid and child
    /// from its own "leash-host" line, the grandchild pid from the relayed
    /// "leash-grandchild" line.
    fn read_tree_announcement(
        reader: impl std::io::BufRead,
    ) -> (libc::pid_t, libc::pid_t, libc::pid_t) {
        let mut pgid: libc::pid_t = 0;
        let mut child: libc::pid_t = 0;
        let mut grandchild: libc::pid_t = 0;
        for line in reader.lines() {
            let line = line.unwrap();
            if let Some(rest) = line.strip_prefix("leash-host ") {
                let mut parts = rest.split(' ');
                pgid = parts.next().unwrap().parse().unwrap();
                child = parts.next().unwrap().parse().unwrap();
            } else if let Some(rest) = line.strip_prefix("leash-grandchild ") {
                grandchild = rest.trim().parse().unwrap();
            }
            if pgid != 0 && grandchild != 0 {
                break;
            }
        }
        (pgid, child, grandchild)
    }

    /// Re-runs this test binary as a disposable host (the ignored fake_host
    /// test below), which leashes a child-plus-grandchild tree, announces
    /// the pids on stdout, and dies the way `mode` says. The leash must take
    /// the whole tree down for every way the host can die, including the
    /// ones that skip all cleanup.
    fn host_death_takes_the_tree_down(mode: &str) {
        let exe = std::env::current_exe().unwrap();
        let mut host = std::process::Command::new(exe)
            .args([
                "leash::tests::fake_host",
                "--exact",
                "--ignored",
                "--nocapture",
            ])
            .env("LEASH_TEST_DEATH_MODE", mode)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let stdout = std::io::BufReader::new(host.stdout.take().unwrap());
        let (pgid, child, grandchild) = read_tree_announcement(stdout);
        assert!(
            pgid > 0 && child > 0 && grandchild > 0,
            "fake host never announced its tree (mode {mode})"
        );
        host.wait().unwrap();
        wait_until_gone(child);
        wait_until_gone(grandchild);
        // The watchdog helper must not linger either.
        wait_until_gone(pgid);
    }

    #[test]
    fn tree_dies_when_the_host_exits_without_cleanup() {
        host_death_takes_the_tree_down("exit");
    }

    #[test]
    fn tree_dies_when_the_host_is_sigkilled() {
        host_death_takes_the_tree_down("sigkill");
    }

    #[test]
    fn tree_dies_when_the_host_aborts() {
        host_death_takes_the_tree_down("abort");
    }

    #[test]
    fn tree_dies_when_the_host_is_sigtermed() {
        host_death_takes_the_tree_down("sigterm");
    }

    /// Runs the close_range-less sweep (the macOS path, shadowed by the
    /// close_range syscall on modern Linux) in a forked child and asserts it
    /// closes exactly the fds at or above the floor. Only async-signal-safe
    /// calls in the child: fcntl and _exit.
    #[test]
    fn the_fallback_fd_sweep_closes_only_fds_at_or_above_the_floor() {
        use std::os::fd::AsRawFd as _;
        let (reader, writer) = io::pipe().unwrap();
        let probe_a = reader.as_raw_fd();
        let probe_b = writer.as_raw_fd();
        assert!(probe_a >= 3 && probe_b >= 3);
        let limit = fd_sweep_limit();
        match unsafe { libc::fork() } {
            -1 => panic!("fork failed"),
            0 => unsafe {
                close_fds_loop(3, limit);
                let mut failures = 0;
                for fd in [0, 1, 2] {
                    if libc::fcntl(fd, libc::F_GETFD) == -1 {
                        failures |= 1; // swept below the floor
                    }
                }
                for fd in [probe_a, probe_b] {
                    if libc::fcntl(fd, libc::F_GETFD) != -1 {
                        failures |= 2; // missed an fd above the floor
                    }
                }
                libc::_exit(failures);
            },
            pid => {
                let mut status: libc::c_int = 0;
                assert_ne!(unsafe { libc::waitpid(pid, &mut status, 0) }, -1);
                assert!(libc::WIFEXITED(status), "sweep child died abnormally");
                assert_eq!(
                    libc::WEXITSTATUS(status),
                    0,
                    "1 = swept below floor, 2 = missed above floor"
                );
            }
        }
    }

    /// True once the helper's sigprocmask has run, so the signal test below
    /// cannot race the helper's startup. Read from /proc on Linux, from
    /// `ps -o blocked=` elsewhere.
    #[cfg(target_os = "linux")]
    fn helper_blocks_sigterm(pid: libc::pid_t) -> bool {
        let Ok(status) = std::fs::read_to_string(format!("/proc/{pid}/status")) else {
            return false;
        };
        status.lines().any(|line| {
            line.strip_prefix("SigBlk:").is_some_and(|hex| {
                u64::from_str_radix(hex.trim(), 16)
                    .is_ok_and(|mask| mask >> (libc::SIGTERM - 1) & 1 == 1)
            })
        })
    }

    /// macOS exposes no way to read another process's signal mask (`ps -o
    /// blocked=` reports 0 there no matter what the mask holds), so watch for
    /// the fd sweep instead: watchdog_main runs it strictly after
    /// sigprocmask, so the mask is up once fd 0 is the helper's only open
    /// file.
    #[cfg(not(target_os = "linux"))]
    fn helper_blocks_sigterm(pid: libc::pid_t) -> bool {
        // Exactly one open fd, and it is fd 0 (the liveness pipe).
        helper_open_fds(pid).as_deref() == Some(&[0])
    }

    /// Only SIGKILL may strip the leash: a catchable signal sent to the
    /// whole group kills the child but must leave the helper (and with it
    /// the backstop and the pgid pin) standing.
    #[test]
    fn a_signal_to_the_group_does_not_strip_the_leash() {
        let (mut child, pgid, watchdog) = leash_spawn(&mut sleeper()).unwrap();
        assert!(watchdog.is_some(), "watchdog fork failed");
        for _ in 0..1000 {
            if helper_blocks_sigterm(pgid) {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert!(helper_blocks_sigterm(pgid), "helper never blocked signals");
        assert_eq!(unsafe { libc::kill(-pgid, libc::SIGTERM) }, 0);
        let status = child.wait().unwrap();
        assert_eq!(status.signal(), Some(libc::SIGTERM));
        assert_eq!(
            unsafe { libc::kill(-pgid, 0) },
            0,
            "the SIGTERM stripped the leash"
        );
        drop(watchdog);
        wait_until_gone(pgid);
    }

    /// The slave side of a PTY master: ptsname_r where it exists, plain
    /// ptsname elsewhere (fine here, the tests hold no other PTYs).
    #[cfg(target_os = "linux")]
    fn pty_slave_path(master: std::os::fd::RawFd) -> String {
        let mut name = [0 as libc::c_char; 128];
        assert_eq!(
            unsafe { libc::ptsname_r(master, name.as_mut_ptr(), name.len()) },
            0
        );
        unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) }
            .to_str()
            .unwrap()
            .to_owned()
    }

    #[cfg(not(target_os = "linux"))]
    fn pty_slave_path(master: std::os::fd::RawFd) -> String {
        let name = unsafe { libc::ptsname(master) };
        assert!(!name.is_null(), "ptsname failed");
        unsafe { std::ffi::CStr::from_ptr(name) }
            .to_str()
            .unwrap()
            .to_owned()
    }

    /// Ctrl+C at a real terminal: SIGINT goes to the foreground process
    /// group only. The fake host becomes a session leader on a fresh PTY, so
    /// the ^C written to the master kills it, while the leash group sits
    /// outside the foreground group, survives the keystroke, and is then
    /// taken down by the watchdog noticing the host's death.
    #[test]
    fn tree_dies_when_the_host_gets_ctrl_c() {
        use std::os::fd::{AsRawFd as _, FromRawFd as _};
        use std::os::unix::process::CommandExt as _;

        let master = unsafe { libc::posix_openpt(libc::O_RDWR | libc::O_NOCTTY) };
        assert!(master >= 0, "posix_openpt failed");
        // CLOEXEC keeps the master out of the host and its tree. A leaked
        // master can never be closed by this test, and closing the master is
        // the only way out of the macOS exit-path wedge described below.
        assert_ne!(
            unsafe { libc::fcntl(master, libc::F_SETFD, libc::FD_CLOEXEC) },
            -1
        );
        let master = unsafe { std::fs::File::from_raw_fd(master) };
        unsafe {
            assert_eq!(libc::grantpt(master.as_raw_fd()), 0);
            assert_eq!(libc::unlockpt(master.as_raw_fd()), 0);
        }
        let slave_path = pty_slave_path(master.as_raw_fd());
        let slave = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(&slave_path)
            .unwrap();

        // Make sure the line discipline turns ^C into SIGINT. ECHO must be
        // off: nothing ever reads the master after the ^C goes in, and on
        // macOS an exiting session leader waits in the kernel for the tty's
        // output queue (which the echoed "^C" would sit in) to drain. With
        // echo on, the host wedges unkillable in its exit path, and every
        // process in the session wedges behind it, until the master closes.
        unsafe {
            let mut tio: libc::termios = std::mem::zeroed();
            assert_eq!(libc::tcgetattr(slave.as_raw_fd(), &mut tio), 0);
            tio.c_lflag |= libc::ISIG;
            tio.c_lflag &= !libc::ECHO;
            assert_eq!(libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &tio), 0);
        }

        let exe = std::env::current_exe().unwrap();
        let mut cmd = std::process::Command::new(exe);
        cmd.args([
            "leash::tests::fake_host",
            "--exact",
            "--ignored",
            "--nocapture",
        ])
        .env("LEASH_TEST_DEATH_MODE", "sigint")
        .stdin(Stdio::from(slave))
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
        unsafe {
            cmd.pre_exec(|| {
                // Fresh session with the PTY (on fd 0) as the controlling
                // terminal and this process's group in the foreground.
                if libc::setsid() == -1 {
                    return Err(io::Error::last_os_error());
                }
                if libc::ioctl(0, libc::TIOCSCTTY as _, 0) == -1 {
                    return Err(io::Error::last_os_error());
                }
                if libc::tcsetpgrp(0, libc::getpgrp()) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut host = cmd.spawn().unwrap();
        let reader = std::io::BufReader::new(host.stdout.take().unwrap());
        let (pgid, child, grandchild) = read_tree_announcement(reader);
        assert!(
            pgid > 0 && child > 0 && grandchild > 0,
            "fake host never announced its tree"
        );

        assert_eq!(
            unsafe { libc::write(master.as_raw_fd(), b"\x03".as_ptr().cast(), 1) },
            1
        );
        let status = host.wait().unwrap();
        assert_eq!(
            status.signal(),
            Some(libc::SIGINT),
            "host did not die from ^C"
        );
        wait_until_gone(child);
        wait_until_gone(grandchild);
        wait_until_gone(pgid);
    }

    /// Not a test: the disposable host that host_death_takes_the_tree_down
    /// re-execs. Ignored so normal runs skip it; a bare `--ignored` run
    /// without the env var makes it a no-op.
    ///
    /// The tree is spawned through the production path, `process_service`
    /// with `leash: true`, which is exactly what `Cmd.spawn_leashed!` does:
    /// the watchdog forks from the tokio service thread and the child joins
    /// its group there. The test-local `leash_spawn` above is only for the
    /// in-process tests that need the Watchdog handle itself.
    #[test]
    #[ignore]
    fn fake_host() {
        let Ok(mode) = std::env::var("LEASH_TEST_DEATH_MODE") else {
            return;
        };
        let mut command = std::process::Command::new("sh");
        command.args(["-c", "sleep 600 & echo leash-grandchild $!; exec sleep 600"]);
        use crate::process_service::{OutputMode, StderrMode, StdinMode};
        let child = crate::process_service::Child::spawn(crate::process_service::Config {
            command,
            stdin: StdinMode::Null,
            stdout: OutputMode::Pipe,
            stderr: StderrMode::Separate(OutputMode::Inherit),
            stdout_file: None,
            stderr_file: None,
            timeout: None,
            output_limit: Some(16 * 1024 * 1024),
            pending_limit: 1024 * 1024,
            manage_tree: true,
            leash: true,
        })
        .unwrap();
        // Relay the grandchild announcement rather than letting the sh write
        // it to the shared stdout: reading it here is what guarantees the
        // grandchild exists before this host dies, otherwise the group kill
        // races the echo and the tree is announced incompletely.
        let mut announcement = Vec::new();
        while !announcement.contains(&b'\n') {
            let event = child
                .read(Duration::from_secs(10))
                .unwrap()
                .expect("child closed stdout before announcing");
            announcement.extend(event.bytes);
        }
        print!("{}", String::from_utf8_lossy(&announcement));
        let pid = child.pid() as libc::pid_t;
        // The group must be the watchdog's, not the child's own: a pgid equal
        // to the pid means the watchdog fork failed and the fallback plain
        // process group is in use, which no host death would clean up.
        let pgid = unsafe { libc::getpgid(pid) };
        assert!(
            pgid > 0 && pgid != pid,
            "leashed child {pid} leads its own group, no watchdog"
        );
        println!("leash-host {pgid} {pid}");
        std::io::stdout().flush().unwrap();
        // The child handle may not be dropped: a Drop here would clean the
        // tree up and the death below would prove nothing.
        std::mem::forget(child);
        match mode.as_str() {
            "exit" => std::process::exit(0),
            "sigkill" => {
                unsafe { libc::raise(libc::SIGKILL) };
            }
            "abort" => std::process::abort(),
            "sigterm" => {
                unsafe { libc::raise(libc::SIGTERM) };
            }
            // For the Ctrl+C test: stay alive until the ^C on the
            // controlling terminal delivers SIGINT.
            "sigint" => loop {
                thread::sleep(Duration::from_secs(600));
            },
            other => panic!("unknown death mode {other}"),
        }
        panic!("still alive after death mode {mode}");
    }
}
