//! File watching for `Watch`.
//!
//! Events from the operating system come through the `notify` crate, one
//! non-recursive watch per folder, so a folder whose name is skipped never
//! costs a watch, and a new folder gets one as soon as a scan finds it.
//!
//! An event only marks a folder to look at again. What is reported comes from
//! comparing each file's size and time of change with the snapshot taken
//! before, so a burst of events for one save is one change, an event that
//! changed nothing is none, and a lost event is caught by comparing every
//! folder. Polling does that comparison on a timer instead of on events.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime};

use notify::Watcher as _;

use crate::roc_platform_abi::*;
use core::mem::ManuallyDrop;

/// How long a burst may keep extending the quiet wait before it is reported
/// anyway, so a process that writes without pause still gets builds.
const MAX_SETTLE: Duration = Duration::from_secs(2);
/// How often a wait checks for a caught signal.
const TICK: Duration = Duration::from_millis(10);

pub(crate) struct Config {
    pub(crate) folders: Vec<PathBuf>,
    pub(crate) trees: Vec<PathBuf>,
    pub(crate) skip: Vec<OsString>,
    pub(crate) poll: Option<Duration>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ChangeKind {
    Created,
    Modified,
    Removed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Change {
    pub(crate) path: PathBuf,
    pub(crate) kind: ChangeKind,
}

#[derive(Debug)]
pub(crate) enum Error {
    Interrupted,
    Io(io::Error),
    /// The operating system has no watches left. The message names the
    /// setting that raises the limit.
    Limit(String),
}

impl From<io::Error> for Error {
    fn from(error: io::Error) -> Self {
        Error::Io(error)
    }
}

fn from_notify(error: notify::Error) -> Error {
    match error.kind {
        notify::ErrorKind::MaxFilesWatch => Error::Limit(
            "The system ran out of file watches. Raise fs.inotify.max_user_watches, \
             for example with `sudo sysctl fs.inotify.max_user_watches=524288`."
                .to_owned(),
        ),
        notify::ErrorKind::Io(error) => Error::Io(error),
        notify::ErrorKind::PathNotFound => Error::Io(io::ErrorKind::NotFound.into()),
        _ => Error::Io(io::Error::other(error.to_string())),
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Stamp {
    size: u64,
    modified: Option<SystemTime>,
}

impl Stamp {
    fn of(metadata: &fs::Metadata) -> Self {
        Self {
            size: metadata.len(),
            modified: metadata.modified().ok(),
        }
    }
}

/// What the event thread has noticed since the last look.
#[derive(Default)]
struct Pending {
    dirty: BTreeSet<PathBuf>,
    rescan: bool,
    last_event: Option<Instant>,
    error: Option<notify::Error>,
}

#[derive(Default)]
struct Shared {
    pending: Mutex<Pending>,
    changed: Condvar,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, Pending> {
        self.pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn note(&self, result: notify::Result<notify::Event>) {
        let mut pending = self.lock();
        match result {
            Ok(event) => {
                // Opening and reading change nothing, and the watch's own scans
                // open folders. A write that finished does count.
                if let notify::EventKind::Access(access) = event.kind {
                    if access != notify::event::AccessKind::Close(notify::event::AccessMode::Write)
                    {
                        return;
                    }
                }
                if event.need_rescan() {
                    pending.rescan = true;
                }
                for path in event.paths {
                    if let Some(parent) = path.parent() {
                        pending.dirty.insert(parent.to_path_buf());
                    }
                    pending.dirty.insert(path);
                }
            }
            // Whatever went wrong, comparing everything catches up.
            Err(error) => {
                pending.rescan = true;
                pending.error.get_or_insert(error);
            }
        }
        pending.last_event = Some(Instant::now());
        self.changed.notify_all();
    }
}

/// What a scan found: every folder it entered, whether it is part of a tree,
/// and every file in them.
#[derive(Default)]
struct Snapshot {
    folders: BTreeMap<PathBuf, bool>,
    files: BTreeMap<PathBuf, Stamp>,
}

/// A watched folder as the caller named it, as the watch keys it, and as
/// FSEvents reports paths below it when a link leads there.
struct Root {
    given: PathBuf,
    absolute: PathBuf,
    canonical: Option<PathBuf>,
}

pub(crate) struct Watcher {
    config: Config,
    roots: Vec<Root>,
    os: Option<notify::RecommendedWatcher>,
    shared: Arc<Shared>,
    snapshot: Snapshot,
    /// Changes found by `set`, reported by the next `next`.
    carried: Vec<Change>,
    next_poll: Instant,
}

impl Watcher {
    pub(crate) fn start(config: Config) -> Result<Self, Error> {
        let shared = Arc::new(Shared::default());
        let os = if config.poll.is_some() {
            None
        } else {
            let handler_shared = Arc::clone(&shared);
            Some(
                notify::recommended_watcher(move |result| handler_shared.note(result))
                    .map_err(from_notify)?,
            )
        };
        let mut watcher = Self {
            config: Config {
                folders: Vec::new(),
                trees: Vec::new(),
                skip: Vec::new(),
                poll: config.poll,
            },
            roots: Vec::new(),
            os,
            shared,
            snapshot: Snapshot::default(),
            carried: Vec::new(),
            next_poll: Instant::now(),
        };
        watcher.set(config)?;
        watcher.carried.clear();
        Ok(watcher)
    }

    /// Watch what `config` names from now on. Files in folders watched before
    /// and after keep their stamps, so changes made meanwhile are reported.
    pub(crate) fn set(&mut self, config: Config) -> Result<(), Error> {
        for root in config.folders.iter().chain(&config.trees) {
            if !fs::symlink_metadata(root)?.is_dir() {
                return Err(Error::Io(io::Error::new(
                    io::ErrorKind::NotADirectory,
                    format!("{} is not a folder", root.display()),
                )));
            }
        }
        // The watch keys every path by its absolute form, which is what the
        // operating system reports, and answers in the form it was given.
        let mut roots = Vec::new();
        let mut absolute = |given: &PathBuf| -> io::Result<PathBuf> {
            let absolute = std::path::absolute(given)?;
            let canonical = fs::canonicalize(&absolute)
                .ok()
                .filter(|canonical| canonical != &absolute);
            roots.push(Root {
                given: given.clone(),
                absolute: absolute.clone(),
                canonical,
            });
            Ok(absolute)
        };
        let folders = config
            .folders
            .iter()
            .map(&mut absolute)
            .collect::<io::Result<Vec<_>>>()?;
        let trees = config
            .trees
            .iter()
            .map(&mut absolute)
            .collect::<io::Result<Vec<_>>>()?;
        let config = Config {
            folders,
            trees,
            skip: config.skip,
            poll: config.poll,
        };
        let old = std::mem::take(&mut self.snapshot);
        self.snapshot.folders = old.folders.clone();
        // Watch first and scan after, so nothing changes unseen in between.
        let first = scan(&config);
        let fresh = self.sync_watches(&first.folders).and_then(|()| {
            let fresh = scan(&config);
            self.sync_watches(&fresh.folders).map(|()| fresh)
        });
        let fresh = match fresh {
            Ok(fresh) => fresh,
            Err(error) => {
                self.snapshot = old;
                return Err(error);
            }
        };
        // A file counts when the watch saw its folder before, or the folder is
        // new inside a tree it watched: files there were made meanwhile.
        let kept = |path: &Path| {
            path.parent().is_some_and(|parent| {
                fresh.folders.contains_key(parent)
                    && (old.folders.contains_key(parent)
                        || parent
                            .ancestors()
                            .skip(1)
                            .any(|ancestor| old.folders.get(ancestor) == Some(&true)))
            })
        };
        let changes = diff(&old.files, &fresh.files, kept);
        self.carried = merge(std::mem::take(&mut self.carried), changes);
        self.snapshot = fresh;
        self.config = config;
        self.roots = roots;
        self.next_poll = Instant::now() + self.config.poll.unwrap_or(Duration::ZERO);
        Ok(())
    }

    fn sync_watches(&mut self, folders: &BTreeMap<PathBuf, bool>) -> Result<(), Error> {
        let Some(os) = self.os.as_mut() else {
            return Ok(());
        };
        for gone in self
            .snapshot
            .folders
            .keys()
            .filter(|folder| !folders.contains_key(*folder))
        {
            let _ = os.unwatch(gone);
        }
        for folder in folders.keys() {
            if !self.snapshot.folders.contains_key(folder) {
                match os.watch(folder, notify::RecursiveMode::NonRecursive) {
                    Ok(()) => {}
                    // Gone again before the watch landed. The next scan sees it.
                    Err(error) if matches!(error.kind, notify::ErrorKind::PathNotFound) => {}
                    Err(error) if matches!(&error.kind, notify::ErrorKind::Io(io) if io.kind() == io::ErrorKind::NotFound) =>
                        {}
                    Err(error) => return Err(from_notify(error)),
                }
            }
        }
        // Remember what is watched now, so a later sync adds and removes the
        // difference. The files are filled in by the caller.
        for folder in folders.keys() {
            self.snapshot.folders.entry(folder.clone()).or_insert(false);
        }
        self.snapshot
            .folders
            .retain(|folder, _| folders.contains_key(folder));
        Ok(())
    }

    /// Wait up to `timeout` for changes, then until nothing has changed for
    /// `quiet`, and report them. An empty list means the timeout passed.
    pub(crate) fn next(
        &mut self,
        timeout: Duration,
        quiet: Duration,
    ) -> Result<Vec<Change>, Error> {
        if !self.carried.is_empty() {
            let carried = std::mem::take(&mut self.carried);
            return Ok(self.to_given(carried));
        }
        let deadline = Instant::now() + timeout;
        loop {
            if crate::signals::is_pending() {
                return Err(Error::Interrupted);
            }
            let changes = match self.config.poll {
                Some(interval) => self.next_polled(deadline, interval, quiet)?,
                None => self.next_from_events(deadline, quiet)?,
            };
            match changes {
                Some(changes) if !changes.is_empty() => return Ok(self.to_given(changes)),
                Some(_) => continue,
                None => return Ok(Vec::new()),
            }
        }
    }

    /// `None` when the deadline passed with nothing to look at.
    fn next_from_events(
        &mut self,
        deadline: Instant,
        quiet: Duration,
    ) -> Result<Option<Vec<Change>>, Error> {
        let shared = Arc::clone(&self.shared);
        let mut pending = shared.lock();
        while pending.dirty.is_empty() && !pending.rescan {
            if crate::signals::is_pending() {
                return Err(Error::Interrupted);
            }
            let Some(left) = deadline.checked_duration_since(Instant::now()) else {
                return Ok(None);
            };
            pending = shared
                .changed
                .wait_timeout(pending, left.min(TICK))
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .0;
        }
        let settle_by = Instant::now() + MAX_SETTLE;
        loop {
            if crate::signals::is_pending() {
                return Err(Error::Interrupted);
            }
            let now = Instant::now();
            let since = pending
                .last_event
                .map_or(quiet, |last| now.duration_since(last));
            if since >= quiet || now >= settle_by {
                break;
            }
            pending = shared
                .changed
                .wait_timeout(pending, (quiet - since).min(TICK))
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .0;
        }
        let dirty = std::mem::take(&mut pending.dirty);
        let rescan = std::mem::take(&mut pending.rescan);
        let error = pending.error.take();
        drop(pending);
        if let Some(error) = error {
            if matches!(error.kind, notify::ErrorKind::MaxFilesWatch) {
                return Err(from_notify(error));
            }
        }
        if rescan {
            self.rescan_all().map(Some)
        } else {
            let dirty = dirty
                .into_iter()
                .map(|path| self.to_internal(path))
                .collect();
            self.rescan_folders(dirty).map(Some)
        }
    }

    fn next_polled(
        &mut self,
        deadline: Instant,
        interval: Duration,
        quiet: Duration,
    ) -> Result<Option<Vec<Change>>, Error> {
        loop {
            let now = Instant::now();
            if now >= self.next_poll {
                self.next_poll = now + interval;
                let mut changes = self.rescan_all()?;
                if changes.is_empty() {
                    return Ok(Some(changes));
                }
                // Let a burst finish before reporting it.
                let settle_by = Instant::now() + MAX_SETTLE;
                loop {
                    sleep_unless_interrupted(quiet)?;
                    let more = self.rescan_all()?;
                    if more.is_empty() || Instant::now() >= settle_by {
                        changes = merge(changes, more);
                        return Ok(Some(changes));
                    }
                    changes = merge(changes, more);
                }
            }
            if now >= deadline {
                return Ok(None);
            }
            sleep_unless_interrupted(self.next_poll.min(deadline) - now)?;
        }
    }

    /// An event's path, keyed as the watch keys it. FSEvents names a path
    /// through a link by where the link leads.
    fn to_internal(&self, path: PathBuf) -> PathBuf {
        if self
            .roots
            .iter()
            .any(|root| path.starts_with(&root.absolute))
        {
            return path;
        }
        for root in &self.roots {
            if let Some(rest) = root
                .canonical
                .as_ref()
                .and_then(|canonical| path.strip_prefix(canonical).ok())
            {
                return root.absolute.join(rest);
            }
        }
        path
    }

    /// Changes with their paths in the form the caller named the folders in.
    fn to_given(&self, changes: Vec<Change>) -> Vec<Change> {
        changes
            .into_iter()
            .map(|change| {
                let root = self
                    .roots
                    .iter()
                    .filter(|root| change.path.starts_with(&root.absolute))
                    .max_by_key(|root| root.absolute.components().count());
                let Some(root) = root else {
                    return change;
                };
                let rest = change
                    .path
                    .strip_prefix(&root.absolute)
                    .unwrap_or(Path::new(""));
                let path = if rest.as_os_str().is_empty() {
                    root.given.clone()
                } else {
                    root.given.join(rest)
                };
                Change {
                    path,
                    kind: change.kind,
                }
            })
            .collect()
    }

    fn rescan_all(&mut self) -> Result<Vec<Change>, Error> {
        let fresh = scan(&self.config);
        self.sync_watches(&fresh.folders)?;
        let changes = diff(&self.snapshot.files, &fresh.files, |_| true);
        self.snapshot = fresh;
        Ok(changes)
    }

    /// Look again at the folders events named. A folder that appeared is
    /// scanned whole, and one that disappeared takes its files with it.
    fn rescan_folders(&mut self, dirty: BTreeSet<PathBuf>) -> Result<Vec<Change>, Error> {
        let mut changes = Vec::new();
        for folder in dirty {
            let Some(&in_tree) = self.snapshot.folders.get(&folder) else {
                continue;
            };
            let mut fresh = Snapshot::default();
            let exists = fs::symlink_metadata(&folder).is_ok_and(|metadata| metadata.is_dir());
            if exists {
                scan_folder(&folder, in_tree, &self.config.skip, &mut fresh, false);
            }
            // Below this folder: its own files, and with a tree, any folders
            // found or lost under it.
            let old_files: BTreeMap<PathBuf, Stamp> = self
                .snapshot
                .files
                .range(folder.clone()..)
                .take_while(|(path, _)| path.starts_with(&folder))
                .filter(|(path, _)| path.parent() == Some(folder.as_path()))
                .map(|(path, stamp)| (path.clone(), *stamp))
                .collect();
            let mut new_files: BTreeMap<PathBuf, Stamp> = fresh
                .files
                .iter()
                .filter(|(path, _)| path.parent() == Some(folder.as_path()))
                .map(|(path, stamp)| (path.clone(), *stamp))
                .collect();
            changes.extend(diff(&old_files, &new_files, |_| true));

            let old_subfolders: Vec<PathBuf> = self
                .snapshot
                .folders
                .keys()
                .filter(|path| path.parent() == Some(folder.as_path()))
                .cloned()
                .collect();
            let new_subfolders: Vec<PathBuf> = fresh
                .folders
                .keys()
                .filter(|path| path.parent() == Some(folder.as_path()))
                .cloned()
                .collect();
            for gone in old_subfolders
                .iter()
                .filter(|path| !new_subfolders.contains(path))
            {
                changes.extend(self.forget_tree(gone));
            }
            for added in new_subfolders
                .iter()
                .filter(|path| !old_subfolders.contains(path))
            {
                changes.extend(self.adopt_tree(added)?);
            }
            for path in old_files.keys() {
                self.snapshot.files.remove(path);
            }
            self.snapshot.files.append(&mut new_files);
            if !exists {
                changes.extend(self.forget_tree(&folder));
            }
        }
        Ok(merge(Vec::new(), changes))
    }

    /// Start watching a folder that appeared in a tree, and report its files.
    fn adopt_tree(&mut self, folder: &Path) -> Result<Vec<Change>, Error> {
        let mut found = Snapshot::default();
        scan_folder(folder, true, &self.config.skip, &mut found, true);
        let mut folders = self.snapshot.folders.clone();
        folders.extend(
            found
                .folders
                .iter()
                .map(|(path, tree)| (path.clone(), *tree)),
        );
        self.sync_watches(&folders)?;
        for (path, tree) in found.folders {
            self.snapshot.folders.insert(path, tree);
        }
        // Files made before the watch landed are caught by this scan.
        let changes = found
            .files
            .keys()
            .map(|path| Change {
                path: path.clone(),
                kind: ChangeKind::Created,
            })
            .collect();
        self.snapshot.files.append(&mut found.files);
        Ok(changes)
    }

    fn forget_tree(&mut self, folder: &Path) -> Vec<Change> {
        let gone_files: Vec<PathBuf> = self
            .snapshot
            .files
            .range(folder.to_path_buf()..)
            .take_while(|(path, _)| path.starts_with(folder))
            .map(|(path, _)| path.clone())
            .collect();
        let gone_folders: Vec<PathBuf> = self
            .snapshot
            .folders
            .range(folder.to_path_buf()..)
            .take_while(|(path, _)| path.starts_with(folder))
            .map(|(path, _)| path.clone())
            .collect();
        for path in &gone_files {
            self.snapshot.files.remove(path);
        }
        for path in &gone_folders {
            if let Some(os) = self.os.as_mut() {
                let _ = os.unwatch(path);
            }
            self.snapshot.folders.remove(path);
        }
        gone_files
            .into_iter()
            .map(|path| Change {
                path,
                kind: ChangeKind::Removed,
            })
            .collect()
    }
}

fn sleep_unless_interrupted(duration: Duration) -> Result<(), Error> {
    if crate::signals::wait_for(duration) {
        Ok(())
    } else {
        Err(Error::Interrupted)
    }
}

fn scan(config: &Config) -> Snapshot {
    let mut snapshot = Snapshot::default();
    for folder in &config.folders {
        scan_folder(folder, false, &config.skip, &mut snapshot, false);
    }
    for tree in &config.trees {
        scan_folder(tree, true, &config.skip, &mut snapshot, true);
    }
    snapshot
}

/// Record a folder and its files, and with `descend`, the folders below it
/// that are not skipped. Links are recorded as files and never followed.
fn scan_folder(
    folder: &Path,
    in_tree: bool,
    skip: &[OsString],
    snapshot: &mut Snapshot,
    descend: bool,
) {
    let entry = snapshot
        .folders
        .entry(folder.to_path_buf())
        .or_insert(false);
    *entry |= in_tree;
    let Ok(entries) = fs::read_dir(folder) else {
        return;
    };
    for entry in entries.flatten() {
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        let path = entry.path();
        if metadata.is_dir() {
            if in_tree && !skip.iter().any(|name| name == &entry.file_name()) {
                if descend {
                    scan_folder(&path, true, skip, snapshot, true);
                } else {
                    snapshot.folders.entry(path).or_insert(true);
                }
            }
        } else {
            snapshot.files.insert(path, Stamp::of(&metadata));
        }
    }
}

fn diff(
    old: &BTreeMap<PathBuf, Stamp>,
    new: &BTreeMap<PathBuf, Stamp>,
    counts: impl Fn(&Path) -> bool,
) -> Vec<Change> {
    let mut changes = Vec::new();
    for (path, stamp) in new {
        match old.get(path) {
            None => {
                if counts(path) {
                    changes.push(Change {
                        path: path.clone(),
                        kind: ChangeKind::Created,
                    });
                }
            }
            Some(previous) if previous != stamp => {
                if counts(path) {
                    changes.push(Change {
                        path: path.clone(),
                        kind: ChangeKind::Modified,
                    });
                }
            }
            Some(_) => {}
        }
    }
    for path in old.keys().filter(|path| !new.contains_key(*path)) {
        if counts(path) {
            changes.push(Change {
                path: path.clone(),
                kind: ChangeKind::Removed,
            });
        }
    }
    changes
}

/// Combine earlier and later changes into one per path, by their net effect.
fn merge(earlier: Vec<Change>, later: Vec<Change>) -> Vec<Change> {
    use ChangeKind::*;
    let mut net: BTreeMap<PathBuf, Option<ChangeKind>> = BTreeMap::new();
    for change in earlier.into_iter().chain(later) {
        let combined = match (
            net.get(&change.path).copied().flatten(),
            net.contains_key(&change.path),
            change.kind,
        ) {
            (_, false, kind) => Some(kind),
            // Made and removed before: it did not exist, whatever comes now.
            (None, true, kind) => Some(kind),
            (Some(Created), _, Removed) => None,
            (Some(Created), _, _) => Some(Created),
            (Some(Removed), _, Created) => Some(Modified),
            (Some(Removed), _, kind) => Some(kind),
            (Some(Modified), _, kind) => Some(kind),
        };
        net.insert(change.path, combined);
    }
    net.into_iter()
        .filter_map(|(path, kind)| kind.map(|kind| Change { path, kind }))
        .collect()
}

// Roc ABI

fn watch_config(
    folders: &RocList<UnixBytesOrUtf8OrWindowsU16s>,
    trees: &RocList<UnixBytesOrUtf8OrWindowsU16s>,
    skip: &RocList<RocStr>,
    poll_nanos: u64,
    roc_host: &RocHost,
) -> io::Result<Config> {
    let paths = |list: &RocList<UnixBytesOrUtf8OrWindowsU16s>| {
        list.as_slice()
            .iter()
            .map(|path| {
                // `path_from_native` consumes a reference, and the caller
                // releases the whole list, so take one for it.
                unsafe { path.incref(1) };
                crate::path_from_native(*path, roc_host)
            })
            .collect::<io::Result<Vec<_>>>()
    };
    Ok(Config {
        folders: paths(folders)?,
        trees: paths(trees)?,
        skip: skip
            .as_slice()
            .iter()
            .map(|name| OsString::from(name.as_str()))
            .collect(),
        poll: (poll_nanos > 0).then(|| Duration::from_nanos(poll_nanos)),
    })
}

fn watch_err(error: Error, roc_host: &RocHost) -> InterruptedOrWatchErrOrWatchLimit {
    match error {
        Error::Interrupted => InterruptedOrWatchErrOrWatchLimit {
            payload: InterruptedOrWatchErrOrWatchLimitPayload { interrupted: [] },
            tag: InterruptedOrWatchErrOrWatchLimitTag::Interrupted,
        },
        Error::Io(error) => InterruptedOrWatchErrOrWatchLimit {
            payload: InterruptedOrWatchErrOrWatchLimitPayload {
                watch_err: ManuallyDrop::new(crate::io_err_from_io(&error, roc_host)),
            },
            tag: InterruptedOrWatchErrOrWatchLimitTag::WatchErr,
        },
        Error::Limit(message) => InterruptedOrWatchErrOrWatchLimit {
            payload: InterruptedOrWatchErrOrWatchLimitPayload {
                watch_limit: ManuallyDrop::new(RocStr::from_str(&message, roc_host)),
            },
            tag: InterruptedOrWatchErrOrWatchLimitTag::WatchLimit,
        },
    }
}

#[no_mangle]
pub extern "C" fn hosted_watch_start(args: HostWatchStartArgs) -> HostWatchStartResult {
    let roc_host = crate::roc_host();
    let config = watch_config(
        &args.folders,
        &args.trees,
        &args.skip,
        args.poll_nanos,
        roc_host,
    );
    unsafe { <HostWatchStartArgsRelease as RocRelease<_>>::release(args, roc_host) };
    let started = config
        .map_err(Error::Io)
        .and_then(Watcher::start)
        .and_then(|watcher| crate::resources::box_resource(watcher, roc_host).map_err(Error::Io));
    match started {
        Ok(handle) => HostWatchStartResult {
            payload: HostWatchStartResultPayload {
                ok: ManuallyDrop::new(handle),
            },
            tag: HostWatchStartResultTag::Ok,
        },
        Err(error) => HostWatchStartResult {
            payload: HostWatchStartResultPayload {
                err: ManuallyDrop::new(watch_err(error, roc_host)),
            },
            tag: HostWatchStartResultTag::Err,
        },
    }
}

#[no_mangle]
pub extern "C" fn hosted_watch_set(
    handle: *mut u64,
    args: AnonStruct640d2538388aa1a6,
) -> HostWatchSetResult {
    let roc_host = crate::roc_host();
    let config = watch_config(
        &args.folders,
        &args.trees,
        &args.skip,
        args.poll_nanos,
        roc_host,
    );
    unsafe { <AnonStruct640d2538388aa1a6Release as RocRelease<_>>::release(args, roc_host) };
    let watcher = unsafe { crate::resources::resource_ref::<Watcher>(handle) };
    let result = config
        .map_err(Error::Io)
        .and_then(|config| watcher.set(config));
    crate::resources::release(handle, roc_host);
    match result {
        Ok(()) => HostWatchSetResult {
            payload: HostWatchSetResultPayload { ok: [] },
            tag: HostWatchSetResultTag::Ok,
        },
        Err(error) => HostWatchSetResult {
            payload: HostWatchSetResultPayload {
                err: ManuallyDrop::new(watch_err(error, roc_host)),
            },
            tag: HostWatchSetResultTag::Err,
        },
    }
}

#[no_mangle]
pub extern "C" fn hosted_watch_next(
    handle: *mut u64,
    timeout_nanos: u64,
    quiet_nanos: u64,
) -> HostWatchNextResult {
    let roc_host = crate::roc_host();
    let watcher = unsafe { crate::resources::resource_ref::<Watcher>(handle) };
    let result = watcher.next(
        Duration::from_nanos(timeout_nanos),
        Duration::from_nanos(quiet_nanos),
    );
    crate::resources::release(handle, roc_host);
    match result {
        Ok(changes) => {
            let list =
                unsafe { RocList::<AnonStruct9f7893148a09d24>::allocate(changes.len(), roc_host) };
            for (index, change) in changes.iter().enumerate() {
                unsafe {
                    list.elements.add(index).write(AnonStruct9f7893148a09d24 {
                        path: crate::native_path_from_path(&change.path, roc_host),
                        kind: match change.kind {
                            ChangeKind::Created => CreatedOrModifiedOrRemoved::Created,
                            ChangeKind::Modified => CreatedOrModifiedOrRemoved::Modified,
                            ChangeKind::Removed => CreatedOrModifiedOrRemoved::Removed,
                        },
                    });
                }
            }
            HostWatchNextResult {
                payload: HostWatchNextResultPayload {
                    ok: ManuallyDrop::new(list),
                },
                tag: HostWatchNextResultTag::Ok,
            }
        }
        Err(error) => HostWatchNextResult {
            payload: HostWatchNextResultPayload {
                err: ManuallyDrop::new(watch_err(error, roc_host)),
            },
            tag: HostWatchNextResultTag::Err,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree_config(root: &Path, poll: Option<Duration>) -> Config {
        Config {
            folders: Vec::new(),
            trees: vec![root.to_path_buf()],
            skip: vec![OsString::from(".git")],
            poll,
        }
    }

    fn kinds(mut changes: Vec<Change>, root: &Path) -> Vec<(String, ChangeKind)> {
        changes.sort_by(|a, b| a.path.cmp(&b.path));
        changes
            .into_iter()
            .map(|change| {
                (
                    change
                        .path
                        .strip_prefix(root)
                        .unwrap()
                        .to_string_lossy()
                        .replace('\\', "/"),
                    change.kind,
                )
            })
            .collect()
    }

    /// Wait for changes until `want` of them have arrived, since a slow
    /// machine may report one save in two lists.
    fn collect(watcher: &mut Watcher, want: usize) -> Vec<Change> {
        let mut all = Vec::new();
        let deadline = Instant::now() + Duration::from_secs(10);
        while all.len() < want && Instant::now() < deadline {
            let more = watcher
                .next(Duration::from_millis(500), Duration::from_millis(50))
                .unwrap();
            all = merge(all, more);
        }
        all
    }

    fn sees_creates_edits_removes_and_new_folders(poll: Option<Duration>) {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        fs::write(root.join("a.roc"), "one").unwrap();
        fs::create_dir(root.join(".git")).unwrap();
        let mut watcher = Watcher::start(tree_config(&root, poll)).unwrap();
        assert!(watcher
            .next(Duration::from_millis(100), Duration::from_millis(20))
            .unwrap()
            .is_empty());

        fs::write(root.join("a.roc"), "one, longer").unwrap();
        fs::write(root.join("b.roc"), "two").unwrap();
        fs::write(root.join(".git/HEAD"), "ignored").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 2), &root),
            [
                ("a.roc".to_owned(), ChangeKind::Modified),
                ("b.roc".to_owned(), ChangeKind::Created)
            ]
        );

        // An editor's save: a new file renamed over the old one.
        fs::write(root.join("a.roc.tmp"), "one, saved").unwrap();
        fs::rename(root.join("a.roc.tmp"), root.join("a.roc")).unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("a.roc".to_owned(), ChangeKind::Modified)]
        );

        fs::create_dir_all(root.join("client/Checkout")).unwrap();
        fs::write(root.join("client/Checkout/cart.roc"), "cart").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("client/Checkout/cart.roc".to_owned(), ChangeKind::Created)]
        );

        // A file in the new folder is watched too.
        fs::write(root.join("client/Checkout/cart.roc"), "cart, edited").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("client/Checkout/cart.roc".to_owned(), ChangeKind::Modified)]
        );

        fs::remove_dir_all(root.join("client")).unwrap();
        fs::remove_file(root.join("b.roc")).unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 2), &root),
            [
                ("b.roc".to_owned(), ChangeKind::Removed),
                ("client/Checkout/cart.roc".to_owned(), ChangeKind::Removed)
            ]
        );
    }

    #[test]
    fn os_events_see_creates_edits_removes_and_new_folders() {
        sees_creates_edits_removes_and_new_folders(None);
    }

    #[test]
    fn polling_sees_creates_edits_removes_and_new_folders() {
        sees_creates_edits_removes_and_new_folders(Some(Duration::from_millis(30)));
    }

    #[test]
    fn a_lost_event_is_caught_by_a_rescan() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        fs::write(root.join("a.roc"), "one").unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();
        // Drop the OS watcher, so no event arrives, and ask for a rescan as an
        // overflowing queue would.
        watcher.os = None;
        fs::write(root.join("a.roc"), "changed while nobody looked").unwrap();
        {
            let mut pending = watcher.shared.lock();
            pending.rescan = true;
            pending.last_event = Some(Instant::now());
        }
        assert_eq!(
            kinds(
                watcher
                    .next(Duration::from_millis(500), Duration::from_millis(10))
                    .unwrap(),
                &root
            ),
            [("a.roc".to_owned(), ChangeKind::Modified)]
        );
    }

    #[test]
    fn set_keeps_state_for_folders_watched_before_and_after() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        fs::create_dir(root.join("one")).unwrap();
        fs::create_dir(root.join("two")).unwrap();
        fs::write(root.join("one/a.roc"), "a").unwrap();
        fs::write(root.join("two/b.roc"), "b").unwrap();
        let folders = |names: &[&str]| Config {
            folders: names.iter().map(|name| root.join(name)).collect(),
            trees: Vec::new(),
            skip: Vec::new(),
            poll: Some(Duration::from_secs(3600)),
        };
        let mut watcher = Watcher::start(folders(&["one"])).unwrap();
        fs::write(root.join("one/a.roc"), "a, edited meanwhile").unwrap();
        watcher.set(folders(&["one", "two"])).unwrap();
        assert_eq!(
            kinds(
                watcher
                    .next(Duration::from_millis(10), Duration::from_millis(10))
                    .unwrap(),
                &root
            ),
            [("one/a.roc".to_owned(), ChangeKind::Modified)]
        );
    }

    #[test]
    fn set_reports_files_in_a_folder_made_meanwhile_in_a_watched_tree() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        fs::write(root.join("first.roc"), "first").unwrap();
        let mut watcher =
            Watcher::start(tree_config(&root, Some(Duration::from_secs(3600)))).unwrap();
        fs::create_dir_all(root.join("Later")).unwrap();
        fs::write(root.join("Later/second.roc"), "second").unwrap();
        watcher
            .set(tree_config(&root, Some(Duration::from_secs(3600))))
            .unwrap();
        assert_eq!(
            kinds(
                watcher
                    .next(Duration::from_millis(10), Duration::from_millis(10))
                    .unwrap(),
                &root
            ),
            [("Later/second.roc".to_owned(), ChangeKind::Created)]
        );
    }

    #[test]
    fn merge_keeps_the_net_effect() {
        use ChangeKind::*;
        let change = |path: &str, kind| Change {
            path: PathBuf::from(path),
            kind,
        };
        assert_eq!(
            merge(
                vec![
                    change("a", Created),
                    change("b", Removed),
                    change("c", Modified)
                ],
                vec![
                    change("a", Removed),
                    change("b", Created),
                    change("c", Removed)
                ]
            ),
            vec![change("b", Modified), change("c", Removed)]
        );
        assert_eq!(
            merge(vec![change("a", Created)], vec![change("a", Modified)]),
            vec![change("a", Created)]
        );
    }

    #[test]
    fn a_missing_folder_is_an_error() {
        let root = tempfile::tempdir().unwrap();
        let result = Watcher::start(tree_config(&root.path().join("absent"), None));
        assert!(matches!(result, Err(Error::Io(error)) if error.kind() == io::ErrorKind::NotFound));
    }
}
