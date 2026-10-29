//! Bounded native DNS for HTTP. Cancelled queued jobs are skipped, and
//! an in-progress getaddrinfo may finish later without retaining any Roc values.
use std::io;
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
use std::time::Duration;

struct Job {
    host: String,
    port: u16,
    cancelled: Arc<AtomicBool>,
    result: mpsc::SyncSender<io::Result<Vec<SocketAddr>>>,
}
struct Ticket {
    cancelled: Arc<AtomicBool>,
}
impl Drop for Ticket {
    fn drop(&mut self) {
        self.cancelled.store(true, Ordering::Release);
    }
}
fn job(host: String, port: u16) -> (Job, Ticket, mpsc::Receiver<io::Result<Vec<SocketAddr>>>) {
    let (sender, receiver) = mpsc::sync_channel(1);
    let cancelled = Arc::new(AtomicBool::new(false));
    (
        Job {
            host,
            port,
            cancelled: cancelled.clone(),
            result: sender,
        },
        Ticket { cancelled },
        receiver,
    )
}
fn resolver() -> &'static mpsc::SyncSender<Job> {
    static RESOLVER: OnceLock<mpsc::SyncSender<Job>> = OnceLock::new();
    RESOLVER.get_or_init(|| {
        let (sender, receiver) = mpsc::sync_channel::<Job>(16);
        let receiver = Arc::new(Mutex::new(receiver));
        for _ in 0..2 {
            let receiver = receiver.clone();
            std::thread::Builder::new()
                .name("basic-cli-resolve".into())
                .spawn(move || loop {
                    let job = receiver.lock().unwrap().recv();
                    let Ok(job) = job else { break };
                    if job.cancelled.load(Ordering::Acquire) {
                        continue;
                    }
                    let result = (job.host.as_str(), job.port)
                        .to_socket_addrs()
                        .map(|addresses| addresses.collect());
                    let _ = job.result.send(result);
                })
                .expect("DNS resolver thread");
        }
        sender
    })
}
fn stopped() -> io::Error {
    io::Error::other("DNS resolver stopped unexpectedly")
}
#[derive(Clone)]
pub(crate) struct HttpResolver;
impl tower_service::Service<hyper_util::client::legacy::connect::dns::Name> for HttpResolver {
    type Response = std::vec::IntoIter<SocketAddr>;
    type Error = io::Error;
    type Future =
        std::pin::Pin<Box<dyn std::future::Future<Output = io::Result<Self::Response>> + Send>>;
    fn poll_ready(&mut self, _: &mut std::task::Context<'_>) -> std::task::Poll<io::Result<()>> {
        std::task::Poll::Ready(Ok(()))
    }
    fn call(&mut self, name: hyper_util::client::legacy::connect::dns::Name) -> Self::Future {
        let host = name.as_str().to_owned();
        Box::pin(async move {
            let (mut job, _ticket, receiver) = job(host, 0);
            loop {
                match resolver().try_send(job) {
                    Ok(()) => break,
                    Err(mpsc::TrySendError::Full(returned)) => {
                        job = returned;
                        tokio::time::sleep(Duration::from_millis(10)).await;
                    }
                    Err(mpsc::TrySendError::Disconnected(_)) => return Err(stopped()),
                }
            }
            loop {
                match receiver.try_recv() {
                    Ok(result) => return result.map(Vec::into_iter),
                    Err(mpsc::TryRecvError::Empty) => {
                        tokio::time::sleep(Duration::from_millis(10)).await
                    }
                    Err(mpsc::TryRecvError::Disconnected) => return Err(stopped()),
                }
            }
        })
    }
}
