//! Broadcasts that `main!` publishes to and event streams read from.
//!
//! An `Events` is an id into a process-wide list, so handlers on other threads
//! can capture it as plain data. It lives until the process ends.
//!
//! The greeting and the channel sit behind one lock: a stream subscribes and
//! copies the greeting under it, and publishing and replacing the greeting take
//! it too, so a stream never misses an event between its greeting and its
//! first message.
use crate::roc_platform_abi::RocListWith;
use bytes::Bytes;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use tokio::sync::broadcast;

pub(crate) struct Broadcast {
    state: Mutex<State>,
}

struct State {
    greeting: Bytes,
    sender: broadcast::Sender<Bytes>,
}

pub(crate) struct Subscription {
    pub(crate) greeting: Bytes,
    pub(crate) receiver: broadcast::Receiver<Bytes>,
}

impl Broadcast {
    fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity.max(1));
        Self {
            state: Mutex::new(State {
                greeting: Bytes::new(),
                sender,
            }),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The number of streams the frame reached.
    pub(crate) fn publish(&self, frame: Bytes) -> u64 {
        let state = self.lock();
        state.sender.send(frame).map_or(0, |count| count as u64)
    }

    pub(crate) fn set_greeting(&self, greeting: Bytes) {
        self.lock().greeting = greeting;
    }

    pub(crate) fn subscribe(&self) -> Subscription {
        let state = self.lock();
        Subscription {
            greeting: state.greeting.clone(),
            receiver: state.sender.subscribe(),
        }
    }

    pub(crate) fn streams(&self) -> u64 {
        self.lock().sender.receiver_count() as u64
    }
}

static BROADCASTS: OnceLock<Mutex<Vec<Arc<Broadcast>>>> = OnceLock::new();

fn broadcasts() -> MutexGuard<'static, Vec<Arc<Broadcast>>> {
    BROADCASTS
        .get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Ids start at 1, so a zero id never names a broadcast.
pub(crate) fn create(capacity: u64) -> u64 {
    let capacity = usize::try_from(capacity).unwrap_or(usize::MAX).min(1 << 20);
    let mut all = broadcasts();
    all.push(Arc::new(Broadcast::new(capacity)));
    all.len() as u64
}

pub(crate) fn get(id: u64) -> Option<Arc<Broadcast>> {
    let index = usize::try_from(id.checked_sub(1)?).ok()?;
    broadcasts().get(index).cloned()
}

// Roc ABI

#[no_mangle]
pub extern "C" fn hosted_events_new(capacity: u64) -> u64 {
    create(capacity)
}

fn take_bytes(bytes: RocListWith<u8, false>) -> Bytes {
    let copy = Bytes::copy_from_slice(bytes.as_slice());
    unsafe { bytes.decref(crate::roc_host()) };
    copy
}

#[no_mangle]
pub extern "C" fn hosted_events_publish(id: u64, frame: RocListWith<u8, false>) -> u64 {
    let frame = take_bytes(frame);
    get(id).map_or(0, |events| events.publish(frame))
}

#[no_mangle]
pub extern "C" fn hosted_events_set_greeting(id: u64, greeting: RocListWith<u8, false>) {
    let greeting = take_bytes(greeting);
    if let Some(events) = get(id) {
        events.set_greeting(greeting);
    }
}

#[no_mangle]
pub extern "C" fn hosted_events_streams(id: u64) -> u64 {
    get(id).map_or(0, |events| events.streams())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streams_start_from_the_greeting_and_get_later_events() {
        let id = create(4);
        let events = get(id).unwrap();
        events.set_greeting(Bytes::from_static(b"event: hello\ndata: 1\n\n"));
        assert_eq!(events.publish(Bytes::from_static(b"data: lost\n\n")), 0);

        let mut first = events.subscribe();
        assert_eq!(first.greeting.as_ref(), b"event: hello\ndata: 1\n\n");
        assert_eq!(events.streams(), 1);
        assert_eq!(events.publish(Bytes::from_static(b"data: a\n\n")), 1);
        assert_eq!(first.receiver.try_recv().unwrap().as_ref(), b"data: a\n\n");

        events.set_greeting(Bytes::from_static(b"event: hello\ndata: 2\n\n"));
        let second = events.subscribe();
        assert_eq!(second.greeting.as_ref(), b"event: hello\ndata: 2\n\n");
        assert_eq!(events.streams(), 2);
        drop(second);
        drop(first);
        assert_eq!(events.streams(), 0);
    }

    #[test]
    fn a_stream_that_falls_behind_sees_lag() {
        let events = get(create(2)).unwrap();
        let mut slow = events.subscribe();
        for index in 0..5u8 {
            events.publish(Bytes::from(vec![index]));
        }
        assert!(matches!(
            slow.receiver.try_recv(),
            Err(broadcast::error::TryRecvError::Lagged(_))
        ));
    }

    #[test]
    fn unknown_ids_name_nothing() {
        assert!(get(0).is_none());
        assert!(get(u64::MAX).is_none());
    }
}
