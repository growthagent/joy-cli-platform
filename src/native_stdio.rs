//! Serialized, cancellable native standard I/O. No Roc allocations or standard
//! library stream locks cross the worker boundary.
use std::collections::VecDeque;
use std::io;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant};

#[cfg(unix)]
#[path = "native_stdio/unix.rs"]
mod sys;
#[cfg(windows)]
#[path = "native_stdio/windows.rs"]
mod sys;

const TICK: Duration = Duration::from_millis(10);
/// How long a read with a zero timeout may wait in the queue to start.
const QUEUED_GRACE: Duration = Duration::from_secs(1);
const CHUNK: usize = 16_384;

#[derive(Clone, Copy, Debug)]
pub enum Stream {
    Stdout,
    Stderr,
}

#[derive(Default)]
struct OwnedRequests {
    cancelled: AtomicBool,
    requests: Mutex<Vec<Weak<Request>>>,
}

#[derive(Clone, Default)]
pub struct Owner(Arc<OwnedRequests>);

impl Owner {
    pub fn is_cancelled(&self) -> bool {
        self.0.cancelled.load(Ordering::Acquire)
    }
    fn track(&self, request: &Arc<Request>) {
        let mut requests = self.0.requests.lock().unwrap();
        requests.retain(|request| request.strong_count() != 0);
        requests.push(Arc::downgrade(request));
        if self.0.cancelled.load(Ordering::Acquire) {
            request.cancel();
        }
    }

    /// Cancel every queued or active forwarding request owned by one child.
    pub fn cancel(&self) {
        self.0.cancelled.store(true, Ordering::Release);
        for request in self.requests() {
            request.cancel();
        }
    }

    fn requests(&self) -> Vec<Arc<Request>> {
        self.0
            .requests
            .lock()
            .unwrap()
            .iter()
            .filter_map(Weak::upgrade)
            .collect()
    }

    pub async fn cancel_and_wait(&self) {
        self.0.cancelled.store(true, Ordering::Release);
        loop {
            let requests = self.requests();
            for request in &requests {
                request.cancel();
            }
            if requests.iter().all(|request| request.done()) {
                return;
            }
            tokio::time::sleep(TICK).await;
        }
    }
}

enum Operation {
    Write(Vec<u8>),
    Read(Read),
}

#[derive(Clone, Copy)]
enum Read {
    Chunk,
    Line,
    ToEnd,
    /// Input that is here already, read without waiting for more.
    Waiting,
}

enum Response {
    Written,
    Bytes(Option<Vec<u8>>),
}

#[derive(Clone, Copy)]
enum Phase {
    Queued,
    Active(usize),
    Done,
}

struct State {
    phase: Phase,
    operation: Option<Operation>,
    result: Option<io::Result<Response>>,
}

struct Request {
    cancelled: AtomicBool,
    state: Mutex<State>,
    changed: Condvar,
}

fn interrupted() -> io::Error {
    io::Error::from(io::ErrorKind::Interrupted)
}

impl Request {
    fn new(operation: Operation) -> Arc<Self> {
        Arc::new(Self {
            cancelled: AtomicBool::new(false),
            state: Mutex::new(State {
                phase: Phase::Queued,
                operation: Some(operation),
                result: None,
            }),
            changed: Condvar::new(),
        })
    }

    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
        let mut state = self.state.lock().unwrap();
        match state.phase {
            Phase::Queued => {
                // A queued request can acknowledge cancellation without waiting
                // for an unrelated blocked request ahead of it.
                state.operation.take();
                state.result = Some(Err(interrupted()));
                state.phase = Phase::Done;
                self.changed.notify_all();
            }
            Phase::Active(thread) => {
                // Hold the phase lock so a late wake cannot cancel a subsequent
                // native operation on the same dedicated thread.
                sys::cancel(thread);
            }
            Phase::Done => {}
        }
    }

    fn done(&self) -> bool {
        matches!(self.state.lock().unwrap().phase, Phase::Done)
    }

    fn wait(&self) -> io::Result<Response> {
        loop {
            if crate::signals::is_pending() {
                self.cancel();
            }
            let mut state = self.state.lock().unwrap();
            if let Some(result) = state.result.take() {
                return result;
            }
            state = self.changed.wait_timeout(state, TICK).unwrap().0;
            drop(state);
        }
    }

    /// Like `wait`, but cancels the request at `deadline`. Returns whether
    /// the deadline cancelled it, so a cancelled read can tell a timeout from
    /// a signal.
    ///
    /// A request still queued at the deadline may wait `grace` more to
    /// start, so a zero timeout still reads input that is already waiting.
    /// A read that `blocks` is cancelled at the deadline once it started. One
    /// that does not, which ends by itself, gets `grace` more too, and is
    /// cancelled only if it is stuck: input poll saw was taken by another
    /// reader first. The cancel repeats every tick, as a wake that lands just
    /// before the read starts is lost.
    fn wait_until(
        &self,
        deadline: Instant,
        grace: Duration,
        blocks: bool,
    ) -> (io::Result<Response>, bool) {
        let mut timed_out = false;
        loop {
            let now = Instant::now();
            let queued = matches!(self.state.lock().unwrap().phase, Phase::Queued);
            if crate::signals::is_pending() {
                self.cancel();
            } else if now >= deadline && ((blocks && !queued) || now >= deadline + grace) {
                timed_out = true;
                self.cancel();
            }
            let mut state = self.state.lock().unwrap();
            if let Some(result) = state.result.take() {
                return (result, timed_out);
            }
            state = self.changed.wait_timeout(state, TICK).unwrap().0;
            drop(state);
        }
    }

    fn finish(&self, result: io::Result<Response>) {
        let mut state = self.state.lock().unwrap();
        state.result = Some(result);
        state.phase = Phase::Done;
        self.changed.notify_all();
    }
}

struct Backend {
    input: mpsc::Sender<Arc<Request>>,
    stdout: mpsc::Sender<Arc<Request>>,
    stderr: mpsc::Sender<Arc<Request>>,
}

type StoredError = (io::ErrorKind, String);

fn backend() -> io::Result<&'static Backend> {
    static BACKEND: OnceLock<Result<Backend, StoredError>> = OnceLock::new();
    match BACKEND.get_or_init(|| {
        sys::prepare().map_err(|error| (error.kind(), error.to_string()))?;
        let result = (|| {
            Ok(Backend {
                input: worker(None)?,
                stdout: worker(Some(Stream::Stdout))?,
                stderr: worker(Some(Stream::Stderr))?,
            })
        })();
        if result.is_err() {
            sys::rollback();
        }
        result.map_err(|error: io::Error| (error.kind(), error.to_string()))
    }) {
        Ok(backend) => Ok(backend),
        Err((kind, message)) => Err(io::Error::new(*kind, message.clone())),
    }
}

/// Set up the native wake mechanism before signal catching is committed.
pub fn prepare() -> io::Result<()> {
    backend().map(|_| ())
}

fn worker(stream: Option<Stream>) -> io::Result<mpsc::Sender<Arc<Request>>> {
    let (sender, receiver) = mpsc::channel::<Arc<Request>>();
    let (started, startup) = mpsc::sync_channel(1);
    std::thread::Builder::new()
        .name(format!(
            "roc-native-{}",
            match stream {
                None => "stdin",
                Some(Stream::Stdout) => "stdout",
                Some(Stream::Stderr) => "stderr",
            }
        ))
        .spawn(move || {
            let thread = match sys::thread() {
                Ok(thread) => {
                    let _ = started.send(Ok(()));
                    thread
                }
                Err(error) => {
                    let _ = started.send(Err(error));
                    return;
                }
            };
            let mut input = Input::default();
            let mut output = sys::Output::default();
            for request in receiver {
                let operation = {
                    let mut state = request.state.lock().unwrap();
                    if matches!(state.phase, Phase::Done) {
                        continue;
                    }
                    state.phase = Phase::Active(thread);
                    state.operation.take().unwrap()
                };
                let result = match operation {
                    Operation::Write(bytes) => {
                        write_request(&mut output, stream.unwrap(), &bytes, &request.cancelled)
                            .map(|()| Response::Written)
                    }
                    Operation::Read(kind) => {
                        input.read(kind, &request.cancelled).map(Response::Bytes)
                    }
                };
                request.finish(result);
            }
        })?;
    startup
        .recv()
        .map_err(|_| io::Error::other("native I/O worker did not start"))??;
    Ok(sender)
}

fn write_request(
    output: &mut sys::Output,
    stream: Stream,
    bytes: &[u8],
    cancelled: &AtomicBool,
) -> io::Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        if cancelled.load(Ordering::Acquire) {
            output.cancel();
            return Err(interrupted());
        }
        let end = bytes.len().min(offset + CHUNK);
        match output.write(stream, &bytes[offset..end], cancelled) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(written) => offset += written,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        }
    }
    if cancelled.load(Ordering::Acquire) {
        output.cancel();
        Err(interrupted())
    } else {
        Ok(())
    }
}

#[derive(Default)]
struct Input {
    buffer: VecDeque<u8>,
    native: sys::Input,
}

impl Input {
    fn read(&mut self, kind: Read, cancelled: &AtomicBool) -> io::Result<Option<Vec<u8>>> {
        if matches!(kind, Read::Waiting) {
            return self.waiting(cancelled);
        }
        loop {
            if cancelled.load(Ordering::Acquire) {
                return Err(interrupted());
            }
            let available = match kind {
                Read::Chunk if !self.buffer.is_empty() => Some(self.buffer.len().min(CHUNK)),
                Read::Line => self
                    .buffer
                    .iter()
                    .position(|&byte| byte == b'\n')
                    .map(|position| position + 1),
                _ => None,
            };
            if let Some(count) = available {
                return Ok(Some(self.take(count, kind)));
            }
            let mut bytes = [0u8; CHUNK];
            match self.native.read(&mut bytes, cancelled) {
                Ok(0) => {
                    if cancelled.load(Ordering::Acquire) {
                        return Err(interrupted());
                    }
                    return if self.buffer.is_empty() && !matches!(kind, Read::ToEnd) {
                        Ok(None)
                    } else {
                        Ok(Some(self.take(self.buffer.len(), kind)))
                    };
                }
                Ok(count) => self.buffer.extend(&bytes[..count]),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
    }

    /// A chunk of input that is here already, empty when there is none and
    /// `None` at the end. It reads only after poll says input is here, so it
    /// does not wait. Another process reading the same terminal or pipe can
    /// take that input first, though, and the read then blocks until a cancel
    /// interrupts it. A wake meant for an earlier read can interrupt it too,
    /// and it then tries again.
    fn waiting(&mut self, cancelled: &AtomicBool) -> io::Result<Option<Vec<u8>>> {
        let mut bytes = [0u8; CHUNK];
        while self.buffer.is_empty() && self.native.ready() {
            match self.native.read(&mut bytes, cancelled) {
                Ok(0) => return Ok(None),
                Ok(count) => self.buffer.extend(&bytes[..count]),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {
                    if cancelled.load(Ordering::Acquire) {
                        return Err(interrupted());
                    }
                }
                Err(_) => break,
            }
        }
        let count = self.buffer.len().min(CHUNK);
        Ok(Some(self.take(count, Read::Chunk)))
    }

    fn take(&mut self, count: usize, kind: Read) -> Vec<u8> {
        let mut bytes: Vec<_> = self.buffer.drain(..count).collect();
        if matches!(kind, Read::Line) && bytes.last() == Some(&b'\n') {
            bytes.pop();
            if bytes.last() == Some(&b'\r') {
                bytes.pop();
            }
        }
        bytes
    }
}

fn submit(operation: Operation, stream: Option<Stream>) -> io::Result<Response> {
    if crate::signals::is_pending() {
        return Err(interrupted());
    }
    let backend = backend()?;
    let sender = match stream {
        None => &backend.input,
        Some(Stream::Stdout) => &backend.stdout,
        Some(Stream::Stderr) => &backend.stderr,
    };
    let request = Request::new(operation);
    sender
        .send(request.clone())
        .map_err(|_| io::Error::other("native I/O worker stopped"))?;
    request.wait()
}

pub fn line(stream: Stream, bytes: &[u8]) -> io::Result<()> {
    if crate::signals::is_pending() {
        return Err(interrupted());
    }
    let mut bytes = bytes.to_vec();
    bytes.push(b'\n');
    submit(Operation::Write(bytes), Some(stream)).map(|_| ())
}

pub fn write(stream: Stream, bytes: &[u8]) -> io::Result<()> {
    if crate::signals::is_pending() {
        return Err(interrupted());
    }
    submit(Operation::Write(bytes.to_vec()), Some(stream)).map(|_| ())
}

fn read(kind: Read) -> io::Result<Option<Vec<u8>>> {
    match submit(Operation::Read(kind), None)? {
        Response::Bytes(bytes) => Ok(bytes),
        Response::Written => unreachable!(),
    }
}

pub fn read_line() -> io::Result<Option<Vec<u8>>> {
    read(Read::Line)
}
pub fn read_chunk() -> io::Result<Option<Vec<u8>>> {
    read(Read::Chunk)
}
pub fn read_to_end() -> io::Result<Vec<u8>> {
    Ok(read(Read::ToEnd)?.unwrap_or_default())
}

/// A chunk, or an empty one when nothing arrived within `timeout`. Bytes that
/// arrive later stay in the shared buffer for the next read.
pub fn read_chunk_within(timeout: Duration) -> io::Result<Option<Vec<u8>>> {
    if crate::signals::is_pending() {
        return Err(interrupted());
    }
    let deadline = Instant::now() + timeout;
    let nothing = Some(Vec::new());
    if !timeout.is_zero() {
        return Ok(read_until(Read::Chunk, deadline, Duration::ZERO)?.unwrap_or(nothing));
    }
    if cfg!(unix) {
        // Unix tells whether input is waiting, so the read never waits.
        return Ok(read_until(Read::Waiting, deadline, QUEUED_GRACE)?.unwrap_or(nothing));
    }
    // Windows does not tell whether input is waiting, so a read looks until
    // the deadline cancels it, and input it left in the buffer is asked for
    // once more.
    match read_until(Read::Chunk, deadline, QUEUED_GRACE)? {
        Some(bytes) => Ok(bytes),
        None => Ok(read_until(Read::Waiting, deadline, QUEUED_GRACE)?.unwrap_or(nothing)),
    }
}

/// A read that the deadline cancels, after `grace` more if it has not
/// started by then. `None` when the deadline cancelled it.
fn read_until(
    kind: Read,
    deadline: Instant,
    grace: Duration,
) -> io::Result<Option<Option<Vec<u8>>>> {
    let request = Request::new(Operation::Read(kind));
    backend()?
        .input
        .send(request.clone())
        .map_err(|_| io::Error::other("native I/O worker stopped"))?;
    let blocks = !matches!(kind, Read::Waiting);
    match request.wait_until(deadline, grace, blocks) {
        (Ok(Response::Bytes(bytes)), _) => Ok(Some(bytes)),
        (Ok(Response::Written), _) => unreachable!(),
        (Err(error), true)
            if error.kind() == io::ErrorKind::Interrupted && !crate::signals::is_pending() =>
        {
            Ok(None)
        }
        (Err(error), _) => Err(error),
    }
}

/// Forwarding ignores application pending signals. Its child owns cancellation.
pub async fn forward(stream: Stream, bytes: Vec<u8>, owner: &Owner) -> io::Result<()> {
    let backend = backend()?;
    let sender = match stream {
        Stream::Stdout => &backend.stdout,
        Stream::Stderr => &backend.stderr,
    };
    let request = Request::new(Operation::Write(bytes));
    owner.track(&request);
    sender
        .send(request.clone())
        .map_err(|_| io::Error::other("native I/O worker stopped"))?;
    loop {
        if owner.is_cancelled() {
            request.cancel();
        }
        if let Some(result) = request.state.lock().unwrap().result.take() {
            return result.map(|_| ());
        }
        tokio::time::sleep(TICK).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, Read as _, Write as _};
    use std::process::{Command, Stdio};

    #[test]
    fn queued_cancellation_does_not_wait_for_the_worker() {
        let request = Request::new(Operation::Write(vec![1; 1024]));
        request.cancel();
        assert!(request.done());
        assert!(request.state.lock().unwrap().operation.is_none());
        assert_eq!(
            request.wait().err().unwrap().kind(),
            io::ErrorKind::Interrupted
        );
    }

    #[test]
    fn a_cancelled_owner_rejects_new_requests() {
        let owner = Owner::default();
        owner.cancel();
        let request = Request::new(Operation::Write(vec![1]));
        owner.track(&request);
        assert!(request.done());
    }

    #[test]
    fn interrupted_input_keeps_the_shared_cursor() {
        let mut input = Input::default();
        input.buffer.extend(b"part\r\nrest");
        let cancelled = AtomicBool::new(true);
        assert_eq!(
            input.read(Read::Line, &cancelled).err().unwrap().kind(),
            io::ErrorKind::Interrupted
        );
        cancelled.store(false, Ordering::Release);
        assert_eq!(
            input.read(Read::Line, &cancelled).unwrap(),
            Some(b"part".to_vec())
        );
        assert_eq!(
            input.read(Read::Chunk, &cancelled).unwrap(),
            Some(b"rest".to_vec())
        );
    }

    // This test is also the isolated child used below. Isolation prevents its
    // actual standard handles or signal disposition affecting other Rust tests.
    #[test]
    fn native_io_helper() {
        let Ok(mode) = std::env::var("BASIC_CLI_NATIVE_IO_TEST") else {
            return;
        };
        if mode == "input" {
            let request = Request::new(Operation::Read(super::Read::Line));
            backend().unwrap().input.send(request.clone()).unwrap();
            let cancellation = request.clone();
            std::thread::spawn(move || {
                while !cancellation.done() {
                    std::thread::sleep(TICK);
                    cancellation.cancel();
                }
            });
            assert_eq!(
                request.wait().err().unwrap().kind(),
                io::ErrorKind::Interrupted
            );
            eprintln!("native cancellation acknowledged");
            let line = read_line().unwrap().unwrap();
            assert_eq!(line, b"partial");
            return;
        }
        if mode == "within" {
            // The parent wrote "abc" and keeps the pipe open.
            std::thread::sleep(Duration::from_millis(100));
            let waiting = read_chunk_within(Duration::ZERO).unwrap().unwrap();
            assert_eq!(waiting, b"abc");
            let started = Instant::now();
            for _ in 0..50 {
                let polled = Instant::now();
                let nothing = read_chunk_within(Duration::ZERO).unwrap().unwrap();
                assert!(nothing.is_empty());
                assert!(polled.elapsed() < Duration::from_secs(1));
            }
            // A poll asks whether input is waiting and never sleeps a tick,
            // except on Windows, which cannot tell without reading.
            if cfg!(unix) {
                assert!(started.elapsed() < Duration::from_millis(250));
            }
            eprintln!("native cancellation acknowledged");
            return;
        }
        #[cfg(unix)]
        if mode == "taken" {
            // Poll says input is here, but the pipe is empty and stays open, so
            // the read blocks as it does when another reader took the input.
            sys::PRETEND_READY.store(true, Ordering::Release);
            let started = Instant::now();
            let nothing = read_chunk_within(Duration::ZERO).unwrap().unwrap();
            assert!(nothing.is_empty());
            assert!(started.elapsed() < QUEUED_GRACE + Duration::from_secs(1));
            eprintln!("native cancellation acknowledged");
            return;
        }
        let stream = if mode == "stderr" {
            Stream::Stderr
        } else {
            Stream::Stdout
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .unwrap();
        runtime.block_on(async {
            let owner = Owner::default();
            let stop = owner.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(100)).await;
                stop.cancel();
            });
            let result = forward(stream, vec![0xa5; 4 * 1024 * 1024], &owner).await;
            assert_eq!(result.unwrap_err().kind(), io::ErrorKind::Interrupted);
            owner.cancel_and_wait().await;
        });
        match stream {
            Stream::Stdout => eprintln!("native cancellation acknowledged"),
            Stream::Stderr => println!("native cancellation acknowledged"),
        }
        let mut ready = [0];
        std::io::stdin().read_exact(&mut ready).unwrap();
        write(stream, b"recovered\n").unwrap();
    }

    fn child(mode: &str) -> std::process::Child {
        Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "native_stdio::tests::native_io_helper",
                "--nocapture",
            ])
            .env("BASIC_CLI_NATIVE_IO_TEST", mode)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
    }

    fn acknowledgement(input: impl io::Read + Send + 'static) -> mpsc::Receiver<()> {
        let (sender, receiver) = mpsc::channel();
        std::thread::spawn(move || {
            for line in io::BufReader::new(input).lines() {
                if line.unwrap().contains("native cancellation acknowledged") {
                    let _ = sender.send(());
                    // Keep the control pipe open through the child test harness's
                    // final report; dropping it here gives that report EPIPE.
                }
            }
        });
        receiver
    }

    #[test]
    fn a_zero_timeout_returns_waiting_input_and_never_hangs() {
        let mut child = child("within");
        let mut stdin = child.stdin.take().unwrap();
        stdin.write_all(b"abc").unwrap();
        let acknowledgement = acknowledgement(child.stderr.take().unwrap());
        let acknowledged = acknowledgement.recv_timeout(Duration::from_secs(10));
        drop(stdin);
        let status = child.wait().unwrap();
        assert!(acknowledged.is_ok() && status.success(), "{status:?}");
    }

    #[cfg(unix)]
    #[test]
    fn a_zero_timeout_read_whose_input_was_taken_still_ends() {
        let mut child = child("taken");
        let stdin = child.stdin.take().unwrap();
        let acknowledgement = acknowledgement(child.stderr.take().unwrap());
        let acknowledged = acknowledgement.recv_timeout(Duration::from_secs(10));
        drop(stdin);
        let status = child.wait().unwrap();
        assert!(acknowledged.is_ok() && status.success(), "{status:?}");
    }

    #[test]
    fn blocked_native_output_stops_and_both_workers_are_reusable() {
        for mode in ["stdout", "stderr"] {
            let mut child = child(mode);
            let mut target: Box<dyn io::Read>;
            let acknowledgement = if mode == "stdout" {
                target = Box::new(child.stdout.take().unwrap());
                acknowledgement(child.stderr.take().unwrap())
            } else {
                target = Box::new(child.stderr.take().unwrap());
                acknowledgement(child.stdout.take().unwrap())
            };
            if acknowledgement
                .recv_timeout(Duration::from_secs(5))
                .is_err()
            {
                let _ = child.kill();
                let _ = child.wait();
                panic!("native output did not acknowledge cancellation");
            }
            child.stdin.take().unwrap().write_all(b"x").unwrap();
            let mut bytes = Vec::new();
            target.read_to_end(&mut bytes).unwrap();
            assert!(child.wait().unwrap().success());
            assert!(bytes.len() < 4 * 1024 * 1024);
            let marker = bytes
                .windows(10)
                .position(|bytes| bytes == b"recovered\n")
                .unwrap();
            assert!(
                !bytes[marker..].contains(&0xa5),
                "canceled output continued after return"
            );
        }
    }

    #[test]
    fn blocked_native_input_retains_partial_bytes_for_the_next_read() {
        let mut child = child("input");
        let acknowledgement = acknowledgement(child.stderr.take().unwrap());
        child.stdin.as_mut().unwrap().write_all(b"part").unwrap();
        if acknowledgement
            .recv_timeout(Duration::from_secs(5))
            .is_err()
        {
            let _ = child.kill();
            let _ = child.wait();
            panic!("native input did not acknowledge cancellation");
        }
        child.stdin.take().unwrap().write_all(b"ial\n").unwrap();
        assert!(child.wait().unwrap().success());
    }
}
