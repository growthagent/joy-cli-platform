//! The HTTP server that `Server.start!` runs beside `main!`.
//!
//! Each server has a thread of its own with a single-threaded Tokio runtime,
//! which accepts connections and speaks HTTP/1. Roc never runs on it: a request
//! goes to the server's pool of handler threads, which call the boxed Roc
//! closure, so a slow handler holds up only its own request. File replies
//! stream from threads of their own (see `file_server`), and event streams wait
//! on their broadcast (see `events`).
//!
//! A server lives until `Server.stop!`, or until `main!` returns, when the host
//! stops whatever is still running.

use crate::events;
use crate::file_server::{CachePolicy, FilePlan, FileRootSpec, FileService, RootError};
use crate::roc_platform_abi::*;
use bytes::Bytes;
use http_body_util::{combinators::UnsyncBoxBody, BodyExt, Empty, Full, Limited};
use hyper::body::{Body, Frame, Incoming};
use hyper::header::{HeaderName, HeaderValue};
use hyper::{HeaderMap, Method, StatusCode};
use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, ToSocketAddrs};
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc as std_mpsc, Arc, Condvar, Mutex, MutexGuard, OnceLock};
use std::task::{Context, Poll};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc, oneshot, watch};

pub(crate) type ServerBody = UnsyncBoxBody<Bytes, io::Error>;
pub(crate) type ServerResponse = hyper::Response<ServerBody>;

pub(crate) type RocServerConfig = AnonStruct69964df4ed722ee8;
type RocRoot = AnonStructB169d1433549ad3;
type RocRequest = AnonStruct8bbc5017d7a8cb36;
type RocHeader = AnonStruct77eaba63dfee299d;
type RocReplyTag = FailedOrFileOrRespondOrStreamTag;

/// Roc runs recursion over long lists on these threads, which needs more than
/// the 2 MiB Rust gives a spawned thread by default.
const HANDLER_STACK_BYTES: usize = 8 * 1024 * 1024;
const QUEUED_PER_HANDLER: usize = 16;
const PING_EVERY: Duration = Duration::from_secs(15);
const STOP_GRACE: Duration = Duration::from_secs(2);
const DRAIN_AT_EXIT: Duration = Duration::from_secs(5);

pub(crate) fn full_body(bytes: Bytes) -> ServerBody {
    Full::new(bytes)
        .map_err(|never| match never {})
        .boxed_unsync()
}

pub(crate) fn empty_body() -> ServerBody {
    Empty::new().map_err(|never| match never {}).boxed_unsync()
}

pub(crate) struct Config {
    host: String,
    port: u16,
    roots: Vec<FileRootSpec>,
    max_body_bytes: u64,
    handlers: usize,
}

pub(crate) enum StartError {
    Bind(io::Error),
    Root(String, io::Error),
    Config(String),
}

/// Copy the configuration out of Roc memory, releasing it.
pub(crate) fn config_from_roc(
    config: RocServerConfig,
    roc_host: &RocHost,
) -> Result<Config, StartError> {
    let host = config.host.as_str().to_owned();
    let mut roots = Vec::with_capacity(config.roots.len());
    let mut problem = None;
    for root in config.roots.as_slice() {
        let root: &RocRoot = root;
        let cache = match CachePolicy::from_abi(root.cache, root.max_age_seconds) {
            Ok(Some(cache)) => cache,
            Ok(None) => CachePolicy::Revalidate,
            Err(message) => {
                problem.get_or_insert(message);
                continue;
            }
        };
        // `path_from_native` consumes a reference, and the whole configuration
        // is released below, so take one for it.
        unsafe { root.path.incref(1) };
        let path = match crate::path_from_native(root.path, roc_host) {
            Ok(path) => path,
            Err(error) => {
                problem.get_or_insert(format!("file root {:?}: {error}", root.name.as_str()));
                continue;
            }
        };
        roots.push(FileRootSpec {
            name: root.name.as_str().to_owned(),
            path,
            cache,
        });
    }
    let parsed = Config {
        host,
        port: config.port,
        roots,
        max_body_bytes: config.max_body_bytes,
        handlers: usize::from(config.handlers),
    };
    unsafe { <AnonStruct69964df4ed722ee8Release as RocRelease<_>>::release(config, roc_host) };
    match problem {
        Some(problem) => Err(StartError::Config(problem)),
        None if parsed.handlers == 0 => Err(StartError::Config(
            "a server needs at least one handler".to_owned(),
        )),
        None => Ok(parsed),
    }
}

/// The boxed Roc closure that answers requests. The server holds one reference
/// and each call takes one more, which the Roc entry point consumes.
pub(crate) struct RocHandler(RocErasedCallable);

// SAFETY: the closure is immutable Roc data. Its refcounts are atomic and the
// host's allocator is thread-safe.
unsafe impl Send for RocHandler {}
unsafe impl Sync for RocHandler {}

impl RocHandler {
    /// Take over the reference `server_start!` was given.
    pub(crate) fn new(callable: RocErasedCallable) -> Self {
        Self(callable)
    }

    fn call(&self, request: RocRequest) -> Reply {
        unsafe { incref_erased_callable(self.0, 1) };
        let reply = unsafe { roc_server_respond_owned(self.0, request) };
        Reply::from_roc(&reply)
    }
}

impl Drop for RocHandler {
    fn drop(&mut self) {
        // A handler thread can outlive `main!` by a moment at exit, when the
        // host is gone and the process is about to end anyway.
        if let Some(roc_host) = crate::roc_host_if_live() {
            unsafe { decref_erased_callable(self.0, roc_host) };
        }
    }
}

/// A handler's reply, copied out of Roc memory on the handler's thread.
enum Reply {
    Respond {
        status: u16,
        headers: Vec<(String, String)>,
        body: Bytes,
    },
    File {
        plan: FilePlan,
        headers: Vec<(String, String)>,
    },
    Stream {
        events: u64,
        headers: Vec<(String, String)>,
    },
    Failed(String),
}

fn headers_from_roc(headers: &RocList<RocHeader>) -> Vec<(String, String)> {
    headers
        .as_slice()
        .iter()
        .map(|header| (header._0.as_str().to_owned(), header._1.as_str().to_owned()))
        .collect()
}

impl Reply {
    fn from_roc(reply: &FailedOrFileOrRespondOrStream) -> Self {
        match reply.tag {
            RocReplyTag::Respond => {
                let respond = unsafe { reply.borrow_payload_respond_unchecked() };
                Reply::Respond {
                    status: respond.status,
                    headers: headers_from_roc(&respond.headers),
                    body: Bytes::copy_from_slice(respond.body.as_slice()),
                }
            }
            RocReplyTag::File => {
                let file = unsafe { reply.borrow_payload_file_unchecked() };
                match CachePolicy::from_abi(file.cache, file.max_age_seconds) {
                    Ok(cache) => Reply::File {
                        plan: FilePlan {
                            root: file.root.as_str().to_owned(),
                            relative: file.path.as_str().to_owned(),
                            cache,
                        },
                        headers: headers_from_roc(&file.headers),
                    },
                    Err(problem) => Reply::Failed(problem),
                }
            }
            RocReplyTag::Stream => {
                let stream = unsafe { reply.borrow_payload_stream_unchecked() };
                Reply::Stream {
                    events: stream.events,
                    headers: headers_from_roc(&stream.headers),
                }
            }
            RocReplyTag::Failed => Reply::Failed(
                unsafe { reply.borrow_payload_failed_unchecked() }
                    .as_str()
                    .to_owned(),
            ),
        }
    }
}

// Numeric method tags must match `to_host_method` in platform/InternalHttp.roc.
fn method_to_roc(method: &Method) -> (u8, &str) {
    match *method {
        Method::CONNECT => (0, ""),
        Method::DELETE => (1, ""),
        Method::GET => (3, ""),
        Method::HEAD => (4, ""),
        Method::OPTIONS => (5, ""),
        Method::PATCH => (6, ""),
        Method::POST => (7, ""),
        Method::PUT => (8, ""),
        Method::TRACE => (9, ""),
        _ => (2, method.as_str()),
    }
}

fn request_to_roc(method: &Method, uri: &str, headers: &HeaderMap, body: &[u8]) -> RocRequest {
    let roc_host = crate::roc_host();
    let (method_tag, method_ext) = method_to_roc(method);
    let roc_headers = unsafe { RocList::<RocHeader>::allocate(headers.len(), roc_host) };
    for (index, (name, value)) in headers.iter().enumerate() {
        unsafe {
            roc_headers.elements.add(index).write(RocHeader {
                _0: RocStr::from_str(name.as_str(), roc_host),
                _1: RocStr::from_str(&String::from_utf8_lossy(value.as_bytes()), roc_host),
            });
        }
    }
    RocRequest {
        timeout_ms: 0,
        body: crate::roc_u8_list_from_slice(body, roc_host),
        headers: roc_headers,
        method_ext: RocStr::from_str(method_ext, roc_host),
        uri: RocStr::from_str(uri, roc_host),
        method: method_tag,
    }
}

type Job = Box<dyn FnOnce() + Send>;

/// A fixed set of handler threads behind a bounded queue. A full queue turns
/// the request away with a 503 rather than letting work pile up.
struct Pool {
    sender: std_mpsc::SyncSender<Job>,
    active: Arc<(Mutex<usize>, Condvar)>,
}

impl Pool {
    fn new(threads: usize, name: &str) -> io::Result<Self> {
        let (sender, receiver) = std_mpsc::sync_channel::<Job>(threads * QUEUED_PER_HANDLER);
        let receiver = Arc::new(Mutex::new(receiver));
        let active = Arc::new((Mutex::new(0usize), Condvar::new()));
        for index in 0..threads {
            let receiver = Arc::clone(&receiver);
            let active = Arc::clone(&active);
            std::thread::Builder::new()
                .name(format!("{name}-{index}"))
                .stack_size(HANDLER_STACK_BYTES)
                .spawn(move || loop {
                    let job = receiver
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .recv();
                    let Ok(job) = job else { break };
                    job();
                    let mut count = active.0.lock().unwrap_or_else(|p| p.into_inner());
                    *count -= 1;
                    active.1.notify_all();
                })?;
        }
        Ok(Self { sender, active })
    }

    /// Queued jobs count as active from here, so the drain at exit waits for
    /// them too.
    fn submit(&self, job: Job) -> bool {
        let (count, idle) = &*self.active;
        *count.lock().unwrap_or_else(|p| p.into_inner()) += 1;
        if self.sender.try_send(job).is_ok() {
            return true;
        }
        *count.lock().unwrap_or_else(|p| p.into_inner()) -= 1;
        idle.notify_all();
        false
    }
}

struct Shared {
    handler: Arc<RocHandler>,
    pool: Pool,
    files: FileService,
    max_body_bytes: u64,
    stopping: watch::Receiver<bool>,
}

struct Running {
    stop: watch::Sender<bool>,
    thread: Option<JoinHandle<()>>,
    active: Arc<(Mutex<usize>, Condvar)>,
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static SERVERS: OnceLock<Mutex<HashMap<u64, Running>>> = OnceLock::new();

fn servers() -> MutexGuard<'static, HashMap<u64, Running>> {
    SERVERS
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// `"localhost"` is 127.0.0.1, so the port a server reports is the one
/// browsers reach, whichever address family they try first.
fn resolve(host: &str, port: u16) -> Result<SocketAddr, StartError> {
    if host.eq_ignore_ascii_case("localhost") {
        return Ok(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), port));
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        return Ok(SocketAddr::new(ip, port));
    }
    (host, port)
        .to_socket_addrs()
        .ok()
        .and_then(|mut addresses| addresses.next())
        .ok_or_else(|| StartError::Config(format!("cannot resolve host {host:?}")))
}

pub(crate) fn start(config: Config, handler: RocHandler) -> Result<(u64, u16), StartError> {
    let files = FileService::activate(config.roots).map_err(|error| match error {
        RootError::Config(problem) => StartError::Config(problem),
        RootError::Root(name, error) => StartError::Root(name, error),
    })?;
    let address = resolve(&config.host, config.port)?;
    let listener = std::net::TcpListener::bind(address).map_err(StartError::Bind)?;
    listener.set_nonblocking(true).map_err(StartError::Bind)?;
    let port = listener.local_addr().map_err(StartError::Bind)?.port();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(StartError::Bind)?;
    let pool =
        Pool::new(config.handlers, &format!("joy-cli-handler-{port}")).map_err(StartError::Bind)?;
    let active = Arc::clone(&pool.active);
    let (stop, stopping) = watch::channel(false);
    let shared = Arc::new(Shared {
        handler: Arc::new(handler),
        pool,
        files,
        max_body_bytes: config.max_body_bytes,
        stopping: stopping.clone(),
    });
    let thread = std::thread::Builder::new()
        .name(format!("joy-cli-server-{port}"))
        .spawn(move || {
            runtime.block_on(async move {
                match tokio::net::TcpListener::from_std(listener) {
                    Ok(listener) => serve(listener, shared, stopping).await,
                    Err(error) => eprintln!("The server on port {port} could not start: {error}"),
                }
            });
        })
        .map_err(StartError::Bind)?;
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    servers().insert(
        id,
        Running {
            stop,
            thread: Some(thread),
            active,
        },
    );
    Ok((id, port))
}

/// Stop a server and wait for its connections to close. Handlers still running
/// finish on their own. Unknown ids, and servers already stopped, do nothing.
pub(crate) fn stop(id: u64) {
    let running = servers().remove(&id);
    if let Some(mut running) = running {
        let _ = running.stop.send(true);
        if let Some(thread) = running.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Stop every server, and give handlers that are still running a moment to
/// finish, since the Roc host they run against goes away after this.
pub(crate) fn stop_all() {
    let ids: Vec<u64> = servers().keys().copied().collect();
    let mut pools = Vec::new();
    for id in ids {
        if let Some(running) = servers().get(&id) {
            pools.push(Arc::clone(&running.active));
        }
        stop(id);
    }
    let deadline = Instant::now() + DRAIN_AT_EXIT;
    for active in pools {
        let (count, idle) = &*active;
        let mut count = count.lock().unwrap_or_else(|p| p.into_inner());
        while *count > 0 {
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                break;
            };
            count = idle
                .wait_timeout(count, left)
                .unwrap_or_else(|p| p.into_inner())
                .0;
        }
    }
}

async fn serve(
    listener: tokio::net::TcpListener,
    shared: Arc<Shared>,
    mut stopping: watch::Receiver<bool>,
) {
    let mut connections = tokio::task::JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    let _ = stream.set_nodelay(true);
                    let shared = Arc::clone(&shared);
                    let mut stopping = stopping.clone();
                    connections.spawn(async move {
                        let service = hyper::service::service_fn(move |request| {
                            handle(request, Arc::clone(&shared))
                        });
                        let connection = hyper::server::conn::http1::Builder::new()
                            .serve_connection(hyper_util::rt::TokioIo::new(stream), service);
                        tokio::pin!(connection);
                        tokio::select! {
                            _ = connection.as_mut() => {}
                            _ = until_stopped(&mut stopping) => {
                                connection.as_mut().graceful_shutdown();
                                let _ = tokio::time::timeout(STOP_GRACE, connection).await;
                            }
                        }
                    });
                }
                // Running out of file descriptors, say. Back off and retry.
                Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
            },
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
            _ = until_stopped(&mut stopping) => break,
        }
    }
    drop(listener);
    let _ = tokio::time::timeout(STOP_GRACE, async {
        while connections.join_next().await.is_some() {}
    })
    .await;
    connections.abort_all();
}

/// Resolves once the server is told to stop, without holding the watch's
/// lock across an await.
async fn until_stopped(stopping: &mut watch::Receiver<bool>) {
    let _ = stopping.wait_for(|stopped| *stopped).await.map(|_| ());
}

fn plain(status: StatusCode, message: &'static str) -> ServerResponse {
    let mut response = hyper::Response::new(full_body(Bytes::from_static(message.as_bytes())));
    *response.status_mut() = status;
    response.headers_mut().insert(
        hyper::header::CONTENT_TYPE,
        HeaderValue::from_static("text/plain; charset=utf-8"),
    );
    response
}

fn add_headers(response: &mut ServerResponse, headers: &[(String, String)]) -> Result<(), String> {
    for (name, value) in headers {
        let name = HeaderName::from_bytes(name.as_bytes())
            .map_err(|_| format!("invalid header name {name:?}"))?;
        let value = HeaderValue::from_str(value)
            .map_err(|_| format!("invalid value for header {name}: {value:?}"))?;
        response.headers_mut().append(name, value);
    }
    Ok(())
}

async fn handle(
    request: hyper::Request<Incoming>,
    shared: Arc<Shared>,
) -> Result<ServerResponse, std::convert::Infallible> {
    let (parts, body) = request.into_parts();
    let limit = usize::try_from(shared.max_body_bytes).unwrap_or(usize::MAX);
    let body = match Limited::new(body, limit).collect().await {
        Ok(collected) => collected.to_bytes(),
        Err(error) if error.is::<http_body_util::LengthLimitError>() => {
            return Ok(plain(StatusCode::PAYLOAD_TOO_LARGE, "Payload Too Large"));
        }
        Err(_) => return Ok(plain(StatusCode::BAD_REQUEST, "Bad Request")),
    };
    let uri = parts
        .uri
        .path_and_query()
        .map_or("/", |path_and_query| path_and_query.as_str())
        .to_owned();

    let (reply_sender, reply_receiver) = oneshot::channel();
    let handler = Arc::clone(&shared.handler);
    let (method, headers) = (parts.method.clone(), parts.headers.clone());
    let job: Job = Box::new(move || {
        // A request whose connection is already gone is not worth answering.
        if reply_sender.is_closed() {
            return;
        }
        let reply = handler.call(request_to_roc(&method, &uri, &headers, &body));
        let _ = reply_sender.send(reply);
    });
    if !shared.pool.submit(job) {
        return Ok(plain(
            StatusCode::SERVICE_UNAVAILABLE,
            "Service Unavailable",
        ));
    }
    let Ok(reply) = reply_receiver.await else {
        return Ok(plain(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Internal Server Error",
        ));
    };

    let (mut response, extra) = match reply {
        Reply::Respond {
            status,
            headers,
            body,
        } => {
            let mut response = hyper::Response::new(full_body(body));
            match StatusCode::from_u16(status) {
                Ok(status) => *response.status_mut() = status,
                Err(_) => {
                    eprintln!(
                        "A handler answered {} {} with the status {status}, which is not one",
                        parts.method, parts.uri
                    );
                    return Ok(plain(
                        StatusCode::INTERNAL_SERVER_ERROR,
                        "Internal Server Error",
                    ));
                }
            }
            (response, headers)
        }
        Reply::File { plan, headers } => (
            shared
                .files
                .serve(plan, &parts.method, &parts.headers)
                .await,
            headers,
        ),
        Reply::Stream { events, headers } => match events::get(events) {
            Some(broadcast) => (
                event_stream(broadcast.subscribe(), shared.stopping.clone()),
                headers,
            ),
            None => {
                eprintln!(
                    "A handler answered {} {} with an event stream for an unknown Events",
                    parts.method, parts.uri
                );
                return Ok(plain(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Internal Server Error",
                ));
            }
        },
        Reply::Failed(message) => {
            eprintln!("Server handler failed for {message}");
            return Ok(plain(
                StatusCode::INTERNAL_SERVER_ERROR,
                "Internal Server Error",
            ));
        }
    };
    if let Err(problem) = add_headers(&mut response, &extra) {
        eprintln!(
            "A handler answered {} {} with an {problem}",
            parts.method, parts.uri
        );
        return Ok(plain(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Internal Server Error",
        ));
    }
    Ok(response)
}

/// The body of an event stream: frames a task feeds it from the broadcast.
struct EventBody {
    frames: mpsc::Receiver<Bytes>,
}

impl Body for EventBody {
    type Data = Bytes;
    type Error = io::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Self::Data>, Self::Error>>> {
        self.frames
            .poll_recv(context)
            .map(|frame| frame.map(|bytes| Ok(Frame::data(bytes))))
    }
}

fn event_stream(
    subscription: events::Subscription,
    mut stopping: watch::Receiver<bool>,
) -> ServerResponse {
    let (sender, frames) = mpsc::channel::<Bytes>(16);
    let events::Subscription {
        greeting,
        mut receiver,
    } = subscription;
    tokio::spawn(async move {
        if !greeting.is_empty() && sender.send(greeting).await.is_err() {
            return;
        }
        let mut ping =
            tokio::time::interval_at(tokio::time::Instant::now() + PING_EVERY, PING_EVERY);
        loop {
            tokio::select! {
                message = receiver.recv() => match message {
                    Ok(frame) => {
                        if sender.send(frame).await.is_err() {
                            return;
                        }
                    }
                    // Fallen behind, or the broadcast is gone. Closing makes
                    // the page reconnect and start again from the greeting.
                    Err(broadcast::error::RecvError::Lagged(_) | broadcast::error::RecvError::Closed) => return,
                },
                _ = ping.tick() => {
                    // A comment keeps proxies from timing the stream out, and
                    // finds a page that went away.
                    if sender.send(Bytes::from_static(b": ping\n\n")).await.is_err() {
                        return;
                    }
                }
                _ = sender.closed() => return,
                _ = until_stopped(&mut stopping) => return,
            }
        }
    });
    let mut response = hyper::Response::new(EventBody { frames }.boxed_unsync());
    let headers = response.headers_mut();
    headers.insert(
        hyper::header::CONTENT_TYPE,
        HeaderValue::from_static("text/event-stream"),
    );
    headers.insert(
        hyper::header::CACHE_CONTROL,
        HeaderValue::from_static("no-cache"),
    );
    response
}

// Roc ABI

fn start_err(error: StartError, roc_host: &RocHost) -> BadConfigOrBadRootOrServerErr {
    use core::mem::ManuallyDrop;
    match error {
        StartError::Bind(error) => BadConfigOrBadRootOrServerErr {
            payload: BadConfigOrBadRootOrServerErrPayload {
                server_err: ManuallyDrop::new(crate::io_err_from_io(&error, roc_host)),
            },
            tag: BadConfigOrBadRootOrServerErrTag::ServerErr,
        },
        StartError::Root(name, error) => BadConfigOrBadRootOrServerErr {
            payload: BadConfigOrBadRootOrServerErrPayload {
                bad_root: ManuallyDrop::new(BadConfigOrBadRootOrServerErrBadRootPayload {
                    _0: RocStr::from_str(&name, roc_host),
                    _1: crate::io_err_from_io(&error, roc_host),
                }),
            },
            tag: BadConfigOrBadRootOrServerErrTag::BadRoot,
        },
        StartError::Config(problem) => BadConfigOrBadRootOrServerErr {
            payload: BadConfigOrBadRootOrServerErrPayload {
                bad_config: ManuallyDrop::new(RocStr::from_str(&problem, roc_host)),
            },
            tag: BadConfigOrBadRootOrServerErrTag::BadConfig,
        },
    }
}

#[no_mangle]
pub extern "C" fn hosted_server_start(
    config: RocServerConfig,
    handler: RocErasedCallable,
) -> HostServerStartResult {
    use core::mem::ManuallyDrop;
    let roc_host = crate::roc_host();
    // Owns the reference Roc passed, and releases it if the server never starts.
    let handler = RocHandler::new(handler);
    match config_from_roc(config, roc_host).and_then(|config| start(config, handler)) {
        Ok((id, port)) => HostServerStartResult {
            payload: HostServerStartResultPayload {
                ok: ManuallyDrop::new(AnonStructCb49f9579cbbf27 { id, port }),
            },
            tag: HostServerStartResultTag::Ok,
        },
        Err(error) => HostServerStartResult {
            payload: HostServerStartResultPayload {
                err: ManuallyDrop::new(start_err(error, roc_host)),
            },
            tag: HostServerStartResultTag::Err,
        },
    }
}

#[no_mangle]
pub extern "C" fn hosted_server_stop(id: u64) {
    stop(id);
}
