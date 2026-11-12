//! File watching for `Watch`.
//!
//! Events from the operating system come through the `notify` crate. On Linux
//! and Windows that is one non-recursive watch per folder, so a folder whose
//! name is skipped never costs a watch, and a new folder gets one as soon as a
//! scan finds it. On macOS it is one FSEvents watch per root, recursive for a
//! tree, since FSEvents restarts its stream whenever the watched paths change.
//!
//! A folder that is removed takes its watch with it, so one that comes back
//! under the same name is scanned and watched anew, and a missing root is
//! looked for until it is back.
//!
//! An event only marks a folder to look at again. What is reported comes from
//! comparing each file's size, time of change and inode, and the contents of
//! a file changed too recently to tell by its time, with the snapshot taken
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
/// How often a wait looks for watched folders that are missing.
const LOOK_FOR_MISSING: Duration = Duration::from_millis(100);

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

/// How recent a file's time of change can be and still match a later change,
/// on filesystems that keep it in whole seconds or two.
const RACY: Duration = Duration::from_secs(2);
/// Files larger than this are compared by their stamp alone.
const HASH_LIMIT: u64 = 1 << 20;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Stamp {
    size: u64,
    modified: Option<SystemTime>,
    /// The inode on Unix, so a file saved by renaming another over it differs.
    id: u64,
    /// A hash of the contents, taken while the time of change is too recent
    /// to tell it from a later change of the same size.
    hash: Option<u64>,
}

impl Stamp {
    /// The stamp of the entry at `path`, from its own metadata, not that of
    /// what a link leads to.
    fn of(path: &Path, metadata: &fs::Metadata, now: SystemTime) -> Self {
        let modified = metadata.modified().ok();
        let racy = modified
            .is_none_or(|modified| now.duration_since(modified).map_or(true, |age| age < RACY));
        Self {
            size: metadata.len(),
            modified,
            id: file_id(metadata),
            // Only a regular file is read. A link may lead to anything, and
            // a FIFO or a device may never end.
            hash: if racy && metadata.is_file() {
                content_hash(path, metadata.len())
            } else {
                None
            },
        }
    }

    /// Whether the file changed between `self` and `new`.
    fn differs(&self, new: &Stamp, path: &Path) -> bool {
        if (self.size, self.modified, self.id) != (new.size, new.modified, new.id) {
            return true;
        }
        let Some(old) = self.hash else {
            return false;
        };
        new.hash
            .or_else(|| content_hash(path, new.size))
            .is_some_and(|hash| hash != old)
    }
}

#[cfg(unix)]
fn file_id(metadata: &fs::Metadata) -> u64 {
    std::os::unix::fs::MetadataExt::ino(metadata)
}

#[cfg(not(unix))]
fn file_id(_metadata: &fs::Metadata) -> u64 {
    0
}

/// A hash of a regular file's contents, or `None` for anything else and for
/// a file larger than `HASH_LIMIT`, even one that grew since `size` was
/// taken.
fn content_hash(path: &Path, size: u64) -> Option<u64> {
    use std::hash::{Hash, Hasher};
    use std::io::Read;
    if size > HASH_LIMIT {
        return None;
    }
    let file = open_regular(path).ok()?;
    let mut contents = Vec::new();
    file.take(HASH_LIMIT + 1).read_to_end(&mut contents).ok()?;
    if contents.len() as u64 > HASH_LIMIT {
        return None;
    }
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    contents.hash(&mut hasher);
    Some(hasher.finish())
}

/// Open a regular file to read, without following a link, without waiting
/// for a writer, as opening a FIFO would, and without making a terminal the
/// process's own.
#[cfg(unix)]
fn open_regular(path: &Path) -> io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_NOCTTY)
        .open(path)?;
    if file.metadata()?.is_file() {
        Ok(file)
    } else {
        Err(io::ErrorKind::InvalidInput.into())
    }
}

/// Open a regular file to read, opening a link itself rather than what it
/// leads to.
#[cfg(windows)]
fn open_regular(path: &Path) -> io::Result<fs::File> {
    use std::os::windows::fs::OpenOptionsExt;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)?;
    if file.metadata()?.is_file() {
        Ok(file)
    } else {
        Err(io::ErrorKind::InvalidInput.into())
    }
}

/// What the event thread has noticed since the last look.
#[derive(Default)]
struct Pending {
    dirty: BTreeSet<PathBuf>,
    /// Paths that were removed, renamed away or created. A folder among them
    /// may be a new one under an old name, whose watch died with the old one.
    replaced: BTreeSet<PathBuf>,
    rescan: bool,
    last_event: Option<Instant>,
    error: Option<notify::Error>,
}

/// Where the watch never looks: inside a folder that a tree skips.
#[derive(Default)]
struct Skipping {
    /// Every root, in each form the operating system may name it, and
    /// whether it is a tree.
    roots: Vec<(PathBuf, bool)>,
    names: Vec<OsString>,
}

impl Skipping {
    /// Whether every root that `path` is below skips a folder it is in. The
    /// last part of the path may be a file with a skipped name, which counts.
    fn ignores(&self, path: &Path) -> bool {
        let mut below_a_root = false;
        for (root, tree) in &self.roots {
            let Ok(rest) = path.strip_prefix(root) else {
                continue;
            };
            below_a_root = true;
            let mut folders = rest.components();
            folders.next_back();
            let skipped = *tree
                && folders.any(|folder| {
                    let std::path::Component::Normal(name) = folder else {
                        return false;
                    };
                    self.names.iter().any(|skipped| skipped == name)
                });
            if !skipped {
                return false;
            }
        }
        below_a_root
    }
}

#[derive(Default)]
struct Shared {
    pending: Mutex<Pending>,
    changed: Condvar,
    skipping: Mutex<Skipping>,
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, Pending> {
        self.pending
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn skipping(&self) -> MutexGuard<'_, Skipping> {
        self.skipping
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn note(&self, result: notify::Result<notify::Event>) {
        use notify::event::{AccessKind, AccessMode, ModifyKind, RenameMode};
        use notify::EventKind;
        // FSEvents watches everything below a tree, `.git` and build output
        // included. Noting what happens there would keep a burst from
        // settling and wake the watch for nothing.
        if let Ok(event) = &result {
            if !event.paths.is_empty() && !event.need_rescan() {
                let skipping = self.skipping();
                if event.paths.iter().all(|path| skipping.ignores(path)) {
                    return;
                }
            }
        }
        let mut pending = self.lock();
        match result {
            Ok(event) => {
                // Opening and reading change nothing, and the watch's own scans
                // open folders. A write that finished does count.
                if let EventKind::Access(access) = event.kind {
                    if access != AccessKind::Close(AccessMode::Write) {
                        return;
                    }
                }
                if event.need_rescan() {
                    pending.rescan = true;
                }
                let replaced = match event.kind {
                    EventKind::Create(_) | EventKind::Remove(_) => event.paths.len(),
                    EventKind::Modify(ModifyKind::Name(RenameMode::From | RenameMode::Both)) => 1,
                    EventKind::Modify(ModifyKind::Name(_)) => event.paths.len(),
                    _ => 0,
                };
                for path in event.paths.iter().take(replaced) {
                    pending.replaced.insert(path.clone());
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
    /// Folders the operating system is watching right now, and whether each
    /// watch is recursive.
    watched: BTreeMap<PathBuf, bool>,
    shared: Arc<Shared>,
    snapshot: Snapshot,
    /// Changes found by `set`, reported by the next `next`.
    carried: Vec<Change>,
    next_poll: Instant,
    /// How many times the watches changed. FSEvents restarts its stream for
    /// each, and drops what happens under every root meanwhile.
    restarts: u64,
}

impl Watcher {
    pub(crate) fn start(config: Config) -> Result<Self, Error> {
        let mut watcher = Self {
            config: Config {
                folders: Vec::new(),
                trees: Vec::new(),
                skip: Vec::new(),
                poll: Some(Duration::ZERO),
            },
            roots: Vec::new(),
            os: None,
            watched: BTreeMap::new(),
            shared: Arc::new(Shared::default()),
            snapshot: Snapshot::default(),
            carried: Vec::new(),
            next_poll: Instant::now(),
            restarts: 0,
        };
        watcher.set(config)?;
        watcher.carried.clear();
        Ok(watcher)
    }

    /// Watch what `config` names from now on. Files in folders watched before
    /// and after keep their stamps, so changes made meanwhile are reported.
    pub(crate) fn set(&mut self, config: Config) -> Result<(), Error> {
        for root in config.folders.iter().chain(&config.trees) {
            if !fs::metadata(root)?.is_dir() {
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
        // A failed set leaves the watch as it was, so the watches change only
        // in ways that can be undone: a new OS watcher is dropped, one that
        // polling replaces is kept until the end, and the old watches are
        // made again.
        let before = self.watched.clone();
        let created = config.poll.is_none() && self.os.is_none();
        let retired = if config.poll.is_some() {
            self.os.take()
        } else {
            None
        };
        if created {
            let shared = Arc::clone(&self.shared);
            self.os = Some(
                notify::recommended_watcher(move |result| shared.note(result))
                    .map_err(from_notify)?,
            );
        }
        let fresh = match self.watch_and_scan(&config) {
            Ok(fresh) => fresh,
            Err(error) => {
                if created {
                    self.os = None;
                    self.watched.clear();
                } else if retired.is_some() {
                    self.os = retired;
                } else {
                    let _ = self.sync_watches(&before);
                    // Events from folders watched again may have been lost
                    // meanwhile, so the next look compares everything.
                    self.shared.lock().rescan = true;
                }
                return Err(error);
            }
        };
        if retired.is_some() {
            self.watched.clear();
        }
        let old = std::mem::take(&mut self.snapshot);
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
        *self.shared.skipping() = Skipping {
            roots: roots
                .iter()
                .flat_map(|root| {
                    let tree = config.trees.contains(&root.absolute);
                    std::iter::once((root.absolute.clone(), tree))
                        .chain(root.canonical.clone().map(|canonical| (canonical, tree)))
                })
                .collect(),
            names: config.skip.clone(),
        };
        self.config = config;
        self.roots = roots;
        self.next_poll = Instant::now() + self.config.poll.unwrap_or(Duration::ZERO);
        Ok(())
    }

    /// Scan what `config` names and watch it. Watch first and scan after, so
    /// nothing changes unseen in between.
    fn watch_and_scan(&mut self, config: &Config) -> Result<Snapshot, Error> {
        let first = scan(config);
        self.sync_watches(&desired_watches(config, &first.folders))?;
        let fresh = scan(config);
        self.sync_watches(&desired_watches(config, &fresh.folders))?;
        Ok(fresh)
    }

    /// Make the operating system watch `desired` and nothing else.
    fn sync_watches(&mut self, desired: &BTreeMap<PathBuf, bool>) -> Result<(), Error> {
        let gone: Vec<PathBuf> = self
            .watched
            .iter()
            .filter(|(folder, recursive)| desired.get(*folder) != Some(*recursive))
            .map(|(folder, _)| folder.clone())
            .collect();
        let added = desired
            .iter()
            .filter(|(folder, recursive)| self.watched.get(*folder) != Some(*recursive))
            .map(|(folder, recursive)| (folder.clone(), *recursive))
            .collect();
        self.change_watches(&gone, added)
    }

    /// Stop and start watches in one batch, as FSEvents restarts its stream
    /// for every change. A folder that is gone or cannot be read is left
    /// unwatched, and the next sync tries again.
    fn change_watches(
        &mut self,
        gone: &[PathBuf],
        added: Vec<(PathBuf, bool)>,
    ) -> Result<(), Error> {
        let Some(os) = self.os.as_mut() else {
            return Ok(());
        };
        if gone.is_empty() && added.is_empty() {
            return Ok(());
        }
        let mut paths = os.paths_mut();
        for folder in gone {
            if self.watched.remove(folder).is_some() {
                let _ = paths.remove(folder);
            }
        }
        let mut failed = None;
        for (folder, recursive) in added {
            let mode = if recursive {
                notify::RecursiveMode::Recursive
            } else {
                notify::RecursiveMode::NonRecursive
            };
            match paths.add(&folder, mode) {
                Ok(()) => {
                    self.watched.insert(folder, recursive);
                }
                Err(error) if left_for_later(&error) => {}
                Err(error) => {
                    failed.get_or_insert(error);
                }
            }
        }
        self.restarts += 1;
        paths.commit().map_err(from_notify)?;
        failed.map_or(Ok(()), |error| Err(from_notify(error)))
    }

    fn unwatch(&mut self, folder: &Path) {
        if self.watched.contains_key(folder) {
            let _ = self.change_watches(&[folder.to_path_buf()], Vec::new());
        }
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
            let mut found = Vec::new();
            let looked = match self.config.poll {
                Some(interval) => self.next_polled(deadline, interval, quiet, &mut found),
                None => self.next_from_events(deadline, quiet, &mut found),
            };
            match looked {
                Ok(true) if !found.is_empty() => return Ok(self.to_given(merge(Vec::new(), found))),
                Ok(true) => continue,
                Ok(false) => return Ok(Vec::new()),
                // The snapshot already holds what was found before the
                // error, so the next call reports it.
                Err(error) => {
                    self.carried = merge(Vec::new(), found);
                    return Err(error);
                }
            }
        }
    }

    /// Wait for events and add what they changed to `found`. `false` when the
    /// deadline passed with nothing to look at.
    fn next_from_events(
        &mut self,
        deadline: Instant,
        quiet: Duration,
        found: &mut Vec<Change>,
    ) -> Result<bool, Error> {
        // A watched folder that is gone sends no events when it comes back,
        // so it is looked for now and then.
        let missing = self.missing_roots();
        let mut look_again = Instant::now() + LOOK_FOR_MISSING;
        let shared = Arc::clone(&self.shared);
        let mut pending = shared.lock();
        while pending.dirty.is_empty() && pending.replaced.is_empty() && !pending.rescan {
            if crate::signals::is_pending() {
                return Err(Error::Interrupted);
            }
            let now = Instant::now();
            if !missing.is_empty() && now >= look_again {
                look_again = now + LOOK_FOR_MISSING;
                for root in missing.iter().filter(|root| root.is_dir()) {
                    pending.replaced.insert(root.clone());
                    pending.last_event = Some(now);
                }
                continue;
            }
            let Some(left) = deadline.checked_duration_since(now) else {
                return Ok(false);
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
        let replaced = std::mem::take(&mut pending.replaced);
        let rescan = std::mem::take(&mut pending.rescan);
        let error = pending.error.take();
        drop(pending);
        let looked = self.look_at_events(dirty, replaced, rescan, error, found);
        if looked.is_err() {
            // What the events named was taken from the pending sets, so the
            // next call compares everything to find what this one missed.
            // It does that once per call, so an error that stays is
            // returned each time rather than retried here.
            self.shared.lock().rescan = true;
        }
        looked.map(|()| true)
    }

    /// Look at what the events named and add what changed to `found`.
    fn look_at_events(
        &mut self,
        dirty: BTreeSet<PathBuf>,
        replaced: BTreeSet<PathBuf>,
        rescan: bool,
        error: Option<notify::Error>,
        found: &mut Vec<Change>,
    ) -> Result<(), Error> {
        if let Some(error) = error {
            if matches!(error.kind, notify::ErrorKind::MaxFilesWatch) {
                return Err(from_notify(error));
            }
        }
        if rescan {
            // Events were lost, and with them perhaps the news that a watch
            // died, so every folder is watched again.
            let all: Vec<PathBuf> = self.watched.keys().cloned().collect();
            let _ = self.change_watches(&all, Vec::new());
            found.extend(self.rescan_all()?);
            return Ok(());
        }
        let replaced = replaced
            .into_iter()
            .map(|path| self.to_internal(path))
            .collect();
        let dirty = dirty
            .into_iter()
            .map(|path| self.to_internal(path))
            .collect();
        let restarts = self.restarts;
        self.look_again(dirty, replaced, found)?;
        if cfg!(target_os = "macos") && self.restarts != restarts {
            // Watching a root again restarted the FSEvents stream, which
            // dropped what happened under the other roots meanwhile. The
            // watches match the snapshot now, so comparing every folder
            // restarts nothing.
            found.extend(self.rescan_all()?);
        }
        Ok(())
    }

    /// Compare on a timer and add what changed to `found`. `false` when the
    /// deadline passed before the next comparison.
    fn next_polled(
        &mut self,
        deadline: Instant,
        interval: Duration,
        quiet: Duration,
        found: &mut Vec<Change>,
    ) -> Result<bool, Error> {
        loop {
            let now = Instant::now();
            if now >= self.next_poll {
                self.next_poll = now + interval;
                found.extend(self.rescan_all()?);
                if found.is_empty() {
                    return Ok(true);
                }
                // Let a burst finish before reporting it.
                let settle_by = Instant::now() + MAX_SETTLE;
                loop {
                    sleep_unless_interrupted(quiet)?;
                    let more = self.rescan_all()?;
                    let settled = more.is_empty() || Instant::now() >= settle_by;
                    found.extend(more);
                    if settled {
                        return Ok(true);
                    }
                }
            }
            if now >= deadline {
                return Ok(false);
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
                // Joining an empty rest would add a trailing slash.
                return if rest.as_os_str().is_empty() {
                    root.absolute.clone()
                } else {
                    root.absolute.join(rest)
                };
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

    /// Roots the watch was given that are not there now.
    fn missing_roots(&self) -> Vec<PathBuf> {
        self.config
            .folders
            .iter()
            .chain(&self.config.trees)
            .filter(|root| !self.snapshot.folders.contains_key(*root))
            .cloned()
            .collect()
    }

    /// Whether a folder is part of a tree, from the snapshot, or for a root
    /// that is missing from it, from the config.
    fn in_tree(&self, folder: &Path) -> Option<bool> {
        if let Some(&in_tree) = self.snapshot.folders.get(folder) {
            return Some(in_tree);
        }
        if self.config.trees.iter().any(|tree| tree == folder) {
            Some(true)
        } else if self.config.folders.iter().any(|root| root == folder) {
            Some(false)
        } else {
            None
        }
    }

    fn rescan_all(&mut self) -> Result<Vec<Change>, Error> {
        // Watch first and scan after, so nothing changes unseen in between.
        self.sync_watches(&desired_watches(&self.config, &self.snapshot.folders))?;
        let fresh = scan(&self.config);
        self.sync_watches(&desired_watches(&self.config, &fresh.folders))?;
        let changes = diff(&self.snapshot.files, &fresh.files, |_| true);
        self.snapshot = fresh;
        Ok(changes)
    }

    /// Look again at what events named. A folder that may have been replaced
    /// is scanned whole and watched anew, and the rest only where they changed.
    /// The changes go to `changes` as the snapshot takes them in, so after an
    /// error it holds every change the snapshot holds.
    fn look_again(
        &mut self,
        dirty: BTreeSet<PathBuf>,
        replaced: BTreeSet<PathBuf>,
        changes: &mut Vec<Change>,
    ) -> Result<(), Error> {
        let mut refreshed: Vec<PathBuf> = Vec::new();
        for folder in replaced {
            if refreshed.iter().any(|done| folder.starts_with(done)) {
                continue;
            }
            let Some(in_tree) = self.in_tree(&folder) else {
                continue;
            };
            if crate::signals::is_pending() {
                return Err(Error::Interrupted);
            }
            changes.extend(self.refresh(&folder, in_tree)?);
            refreshed.push(folder);
        }
        let dirty = dirty
            .into_iter()
            .filter(|folder| !refreshed.iter().any(|done| folder.starts_with(done)))
            .collect();
        self.rescan_folders(dirty, changes)
    }

    /// Forget what the watch knew about a folder and what is below it, then
    /// scan and watch it as it is now. After an error the snapshot is as it
    /// was.
    fn refresh(&mut self, folder: &Path, in_tree: bool) -> Result<Vec<Change>, Error> {
        let below = |path: &Path| {
            if in_tree {
                path.starts_with(folder)
            } else {
                path.parent() == Some(folder)
            }
        };
        let old_files: BTreeMap<PathBuf, Stamp> = self
            .snapshot
            .files
            .range(folder.to_path_buf()..)
            .take_while(|(path, _)| path.starts_with(folder))
            .filter(|(path, _)| below(path))
            .map(|(path, stamp)| (path.clone(), *stamp))
            .collect();
        for path in old_files.keys() {
            self.snapshot.files.remove(path);
        }
        let old_folders: BTreeMap<PathBuf, bool> = self
            .snapshot
            .folders
            .range(folder.to_path_buf()..)
            .take_while(|(path, _)| path.starts_with(folder))
            .filter(|(path, _)| path.as_path() == folder || below(path))
            .map(|(path, in_tree)| (path.clone(), *in_tree))
            .collect();
        for path in old_folders.keys() {
            self.snapshot.folders.remove(path);
            // The old watch may still hold on to the folder that was there.
            self.unwatch(path);
        }
        let mut found = match self.scan_and_watch(folder, in_tree, in_tree) {
            Ok(found) => found,
            Err(error) => {
                // The next look compares these with what is there and
                // watches the folders again.
                self.snapshot.files.extend(old_files);
                self.snapshot.folders.extend(old_folders);
                return Err(error);
            }
        };
        let changes = diff(&old_files, &found.files, |_| true);
        self.snapshot.folders.append(&mut found.folders);
        self.snapshot.files.append(&mut found.files);
        Ok(changes)
    }

    /// Look again at the folders events named. A folder that appeared is
    /// scanned whole, and one that disappeared takes its files with it. The
    /// changes go to `changes` as the snapshot takes them in.
    fn rescan_folders(
        &mut self,
        dirty: BTreeSet<PathBuf>,
        changes: &mut Vec<Change>,
    ) -> Result<(), Error> {
        for folder in dirty {
            let Some(&in_tree) = self.snapshot.folders.get(&folder) else {
                continue;
            };
            if crate::signals::is_pending() {
                return Err(Error::Interrupted);
            }
            let mut fresh = Snapshot::default();
            let exists = fs::symlink_metadata(&folder).is_ok_and(|metadata| metadata.is_dir());
            if exists {
                // A folder that could not be read when it was found has no
                // watch yet. Watch it before scanning, so nothing is missed.
                fresh.folders.insert(folder.clone(), in_tree);
                self.watch_found(&fresh)?;
                scan_folder(&folder, in_tree, &self.config.skip, &mut fresh, false);
            }
            let old_files: BTreeMap<PathBuf, Stamp> = children(
                self.snapshot
                    .files
                    .range(folder.clone()..)
                    .map(|(path, _)| path),
                &folder,
            )
            .into_iter()
            .filter_map(|path| {
                let stamp = self.snapshot.files.remove(&path)?;
                Some((path, stamp))
            })
            .collect();
            let mut new_files: BTreeMap<PathBuf, Stamp> = std::mem::take(&mut fresh.files)
                .into_iter()
                .filter(|(path, _)| path.parent() == Some(folder.as_path()))
                .collect();
            changes.extend(diff(&old_files, &new_files, |_| true));
            self.snapshot.files.append(&mut new_files);

            let old_subfolders = children(
                self.snapshot
                    .folders
                    .range(folder.clone()..)
                    .map(|(path, _)| path),
                &folder,
            );
            let new_subfolders = children(fresh.folders.keys(), &folder);
            for gone in old_subfolders.difference(&new_subfolders) {
                changes.extend(self.forget_tree(gone));
            }
            for added in new_subfolders.difference(&old_subfolders) {
                changes.extend(self.adopt_tree(added)?);
            }
            if !exists {
                changes.extend(self.forget_tree(&folder));
            }
        }
        Ok(())
    }

    /// Start watching a folder that appeared in a tree, and report its files.
    /// After an error the snapshot is as it was.
    fn adopt_tree(&mut self, folder: &Path) -> Result<Vec<Change>, Error> {
        let mut found = self.scan_and_watch(folder, true, true)?;
        self.snapshot.folders.append(&mut found.folders);
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

    /// Scan a folder, watch what the scan found, and scan again, so files
    /// made before the watches landed are seen.
    fn scan_and_watch(
        &mut self,
        folder: &Path,
        in_tree: bool,
        descend: bool,
    ) -> Result<Snapshot, Error> {
        let mut found = Snapshot::default();
        scan_folder(folder, in_tree, &self.config.skip, &mut found, descend);
        if self.os.is_none() {
            return Ok(found);
        }
        self.watch_found(&found)?;
        let mut again = Snapshot::default();
        scan_folder(folder, in_tree, &self.config.skip, &mut again, descend);
        self.watch_found(&again)?;
        Ok(again)
    }

    fn watch_found(&mut self, found: &Snapshot) -> Result<(), Error> {
        let added = desired_watches(&self.config, &found.folders)
            .into_iter()
            .filter(|(folder, recursive)| self.watched.get(folder) != Some(recursive))
            .collect();
        self.change_watches(&[], added)
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
            self.unwatch(path);
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

/// The paths directly in `folder`, from paths sorted from `folder` on.
fn children<'a>(paths: impl Iterator<Item = &'a PathBuf>, folder: &Path) -> BTreeSet<PathBuf> {
    paths
        .take_while(|path| path.starts_with(folder))
        .filter(|path| path.parent() == Some(folder))
        .cloned()
        .collect()
}

/// The watches the operating system should hold for a scan's folders, and
/// whether each is recursive.
fn desired_watches(config: &Config, folders: &BTreeMap<PathBuf, bool>) -> BTreeMap<PathBuf, bool> {
    folders
        .keys()
        .filter_map(|folder| Some((folder.clone(), watch_mode(config, folder)?)))
        .collect()
}

/// Whether a folder gets a watch of its own, and if so whether it is
/// recursive. inotify and ReadDirectoryChangesW watch every folder alone.
#[cfg(not(target_os = "macos"))]
fn watch_mode(_config: &Config, _folder: &Path) -> Option<bool> {
    Some(false)
}

/// FSEvents restarts its stream whenever the watched paths change, so it
/// watches the roots, a tree with everything below it.
#[cfg(target_os = "macos")]
fn watch_mode(config: &Config, folder: &Path) -> Option<bool> {
    let below_a_tree = config
        .trees
        .iter()
        .any(|tree| folder != tree && folder.starts_with(tree));
    if below_a_tree {
        None
    } else if config.trees.iter().any(|tree| tree == folder) {
        Some(true)
    } else if config.folders.iter().any(|root| root == folder) {
        Some(false)
    } else {
        None
    }
}

/// Whether a watch failed for a reason the next sync may not have: the
/// folder is gone or cannot be read for now.
fn left_for_later(error: &notify::Error) -> bool {
    match &error.kind {
        notify::ErrorKind::PathNotFound => true,
        notify::ErrorKind::Io(io) => matches!(
            io.kind(),
            io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied
        ),
        _ => false,
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
    let now = SystemTime::now();
    for folder in &config.folders {
        scan_folder_at(folder, false, &config.skip, &mut snapshot, false, now);
    }
    for tree in &config.trees {
        scan_folder_at(tree, true, &config.skip, &mut snapshot, true, now);
    }
    snapshot
}

/// Record a folder and its files, and with `descend`, the folders below it
/// that are not skipped. Links are recorded as files and never followed. A
/// folder that is not there is not recorded.
fn scan_folder(
    folder: &Path,
    in_tree: bool,
    skip: &[OsString],
    snapshot: &mut Snapshot,
    descend: bool,
) {
    scan_folder_at(folder, in_tree, skip, snapshot, descend, SystemTime::now());
}

fn scan_folder_at(
    folder: &Path,
    in_tree: bool,
    skip: &[OsString],
    snapshot: &mut Snapshot,
    descend: bool,
    now: SystemTime,
) {
    let entries = match fs::read_dir(folder) {
        Ok(entries) => Some(entries),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return,
        Err(error) if error.kind() == io::ErrorKind::NotADirectory => return,
        // Unreadable, perhaps for now: the folder stays known.
        Err(_) => None,
    };
    let entry = snapshot
        .folders
        .entry(folder.to_path_buf())
        .or_insert(false);
    *entry |= in_tree;
    let Some(entries) = entries else {
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
                    scan_folder_at(&path, true, skip, snapshot, true, now);
                } else {
                    snapshot.folders.entry(path).or_insert(true);
                }
            }
        } else {
            let stamp = Stamp::of(&path, &metadata, now);
            snapshot.files.insert(path, stamp);
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
            Some(previous) if previous.differs(stamp, path) => {
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
            // Made and removed before: it did not exist. Removing it again
            // leaves it so, and anything else makes it.
            (None, true, Removed) => None,
            (None, true, _) => Some(Created),
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
        // A file made and removed was never there to be removed again.
        assert_eq!(
            merge(
                vec![change("a", Created), change("a", Removed)],
                vec![change("a", Removed)]
            ),
            vec![]
        );
        assert_eq!(
            merge(
                vec![change("a", Created), change("a", Removed)],
                vec![change("a", Modified)]
            ),
            vec![change("a", Created)]
        );
    }

    #[test]
    fn a_folder_removed_and_made_again_in_one_burst_is_still_watched() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        fs::create_dir_all(root.join("gen/deep")).unwrap();
        fs::write(root.join("gen/a.roc"), "a").unwrap();
        fs::write(root.join("gen/deep/b.roc"), "b").unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        // A generator that clears its output folder and writes it again.
        fs::remove_dir_all(root.join("gen")).unwrap();
        fs::create_dir_all(root.join("gen/deep")).unwrap();
        fs::write(root.join("gen/a.roc"), "a, again").unwrap();
        fs::write(root.join("gen/deep/b.roc"), "b, again").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 2), &root),
            [
                ("gen/a.roc".to_owned(), ChangeKind::Modified),
                ("gen/deep/b.roc".to_owned(), ChangeKind::Modified)
            ]
        );

        fs::write(root.join("gen/a.roc"), "a, edited later").unwrap();
        fs::write(root.join("gen/deep/b.roc"), "b, edited later").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 2), &root),
            [
                ("gen/a.roc".to_owned(), ChangeKind::Modified),
                ("gen/deep/b.roc".to_owned(), ChangeKind::Modified)
            ]
        );
    }

    #[test]
    fn a_root_removed_and_made_again_is_watched_again() {
        let parent = tempfile::tempdir().unwrap();
        let parent = parent.path().canonicalize().unwrap();
        let root = parent.join("client");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("a.roc"), "a").unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        fs::remove_dir_all(&root).unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("a.roc".to_owned(), ChangeKind::Removed)]
        );

        fs::create_dir_all(root.join("sub")).unwrap();
        fs::write(root.join("sub/b.roc"), "b").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("sub/b.roc".to_owned(), ChangeKind::Created)]
        );

        fs::write(root.join("sub/b.roc"), "b, edited").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("sub/b.roc".to_owned(), ChangeKind::Modified)]
        );
    }

    #[test]
    fn a_root_removed_then_made_again_later_is_watched_again() {
        // Not canonicalized, so on macOS events come through /private/var.
        let parent = tempfile::tempdir().unwrap();
        let root = parent.path().join("root");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("a.roc"), "a").unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        fs::remove_dir_all(&root).unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("a.roc".to_owned(), ChangeKind::Removed)]
        );

        fs::create_dir(&root).unwrap();
        fs::write(root.join("c.roc"), "c").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("c.roc".to_owned(), ChangeKind::Created)]
        );

        fs::write(root.join("c.roc"), "c, edited").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("c.roc".to_owned(), ChangeKind::Modified)]
        );
    }

    #[cfg(unix)]
    #[test]
    fn an_event_on_a_linked_root_names_the_root_as_given() {
        let parent = tempfile::tempdir().unwrap();
        let real = parent.path().canonicalize().unwrap().join("real");
        fs::create_dir(&real).unwrap();
        let link = parent.path().join("link");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let watcher = Watcher::start(tree_config(&link, None)).unwrap();
        let internal = watcher.to_internal(real.clone());
        assert_eq!(
            internal.as_os_str(),
            std::path::absolute(&link).unwrap().as_os_str()
        );
    }

    #[test]
    fn a_root_replaced_in_one_burst_is_watched_again() {
        let parent = tempfile::tempdir().unwrap();
        let parent = parent.path().canonicalize().unwrap();
        let root = parent.join("client");
        fs::create_dir(&root).unwrap();
        fs::write(root.join("a.roc"), "a").unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        fs::remove_dir_all(&root).unwrap();
        fs::create_dir(&root).unwrap();
        fs::write(root.join("a.roc"), "a, again").unwrap();
        let first = kinds(collect(&mut watcher, 1), &root);
        assert_eq!(first, [("a.roc".to_owned(), ChangeKind::Modified)]);

        fs::write(root.join("a.roc"), "a, edited later").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("a.roc".to_owned(), ChangeKind::Modified)]
        );
    }

    #[test]
    fn an_edit_that_keeps_the_size_and_the_time_is_seen() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let file = root.join("a.roc");
        fs::write(&file, "x = 1").unwrap();
        let time = fs::metadata(&file).unwrap().modified().unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        // As on a filesystem that keeps whole seconds: same size, same time.
        fs::write(&file, "x = 2").unwrap();
        fs::File::options()
            .write(true)
            .open(&file)
            .unwrap()
            .set_modified(time)
            .unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("a.roc".to_owned(), ChangeKind::Modified)]
        );
    }

    #[cfg(unix)]
    #[test]
    fn an_unreadable_folder_does_not_end_the_watch() {
        use std::os::unix::fs::PermissionsExt;
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        fs::create_dir(root.join("locked")).unwrap();
        fs::set_permissions(root.join("locked"), fs::Permissions::from_mode(0o000)).unwrap();
        fs::write(root.join("a.roc"), "a").unwrap();
        let changes = kinds(collect(&mut watcher, 1), &root);
        fs::set_permissions(root.join("locked"), fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(changes, [("a.roc".to_owned(), ChangeKind::Created)]);
    }

    #[cfg(unix)]
    #[test]
    fn a_linked_root_is_watched() {
        let parent = tempfile::tempdir().unwrap();
        let parent = parent.path().canonicalize().unwrap();
        fs::create_dir(parent.join("real")).unwrap();
        std::os::unix::fs::symlink(parent.join("real"), parent.join("link")).unwrap();
        let root = parent.join("link");
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        fs::write(root.join("a.roc"), "a").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("a.roc".to_owned(), ChangeKind::Created)]
        );
    }

    #[test]
    fn set_can_switch_from_polling_to_events() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let mut watcher =
            Watcher::start(tree_config(&root, Some(Duration::from_secs(3600)))).unwrap();
        watcher.set(tree_config(&root, None)).unwrap();

        fs::write(root.join("a.roc"), "a").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("a.roc".to_owned(), ChangeKind::Created)]
        );
    }

    #[test]
    fn a_burst_of_many_new_folders_is_reported_quickly() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let count = 2000;
        for index in 0..count {
            fs::create_dir_all(root.join(format!("src/{index}"))).unwrap();
        }
        fs::create_dir(root.join("pkg")).unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        for index in 0..count {
            let folder = root.join(format!("pkg/{index}"));
            fs::create_dir_all(&folder).unwrap();
            fs::write(folder.join("index.js"), "x").unwrap();
        }
        // `collect` gives up after 10 seconds, so a slow report fails here.
        assert_eq!(collect(&mut watcher, count).len(), count);
    }

    #[test]
    fn an_edit_of_a_file_there_from_the_start_is_seen() {
        // Not canonicalized, so on macOS events come through /private/var.
        let root = tempfile::tempdir().unwrap();
        let root = root.path().to_path_buf();
        fs::write(root.join("a.roc"), "one").unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        fs::write(root.join("a.roc"), "two!").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("a.roc".to_owned(), ChangeKind::Modified)]
        );
    }

    #[test]
    fn a_folder_made_again_is_reported_in_the_form_it_was_given() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().to_path_buf();
        fs::create_dir(root.join("sub")).unwrap();
        fs::write(root.join("sub/a.roc"), "a").unwrap();
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        fs::remove_dir_all(root.join("sub")).unwrap();
        fs::create_dir(root.join("sub")).unwrap();
        fs::write(root.join("sub/b.roc"), "b").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 2), &root),
            [
                ("sub/a.roc".to_owned(), ChangeKind::Removed),
                ("sub/b.roc".to_owned(), ChangeKind::Created)
            ]
        );

        fs::write(root.join("sub/b.roc"), "b, edited").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("sub/b.roc".to_owned(), ChangeKind::Modified)]
        );
    }

    #[test]
    fn a_rescan_flag_asks_for_a_rescan() {
        let shared = Shared::default();
        shared.note(Ok(notify::Event::new(notify::EventKind::Other)
            .set_flag(notify::event::Flag::Rescan)
            .add_path(PathBuf::from("/somewhere"))));
        assert!(shared.lock().rescan);
    }

    #[test]
    fn a_missing_folder_is_an_error() {
        let root = tempfile::tempdir().unwrap();
        let result = Watcher::start(tree_config(&root.path().join("absent"), None));
        assert!(matches!(result, Err(Error::Io(error)) if error.kind() == io::ErrorKind::NotFound));
    }

    #[cfg(unix)]
    #[test]
    fn a_fifo_in_a_tree_does_not_stop_the_watch() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let fifo = std::ffi::CString::new(root.join("pipe").into_os_string().into_encoded_bytes())
            .unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o644) }, 0);

        // Opening a FIFO waits for a writer that never comes, so the watch
        // starts on a thread of its own and the test gives up on it.
        let (sender, receiver) = std::sync::mpsc::channel();
        let config = tree_config(&root, None);
        std::thread::spawn(move || {
            let _ = sender.send(Watcher::start(config).is_ok());
        });
        assert_eq!(receiver.recv_timeout(Duration::from_secs(10)), Ok(true));

        // A scan reads only regular files, so it never opens the FIFO. Opening
        // it to hash it must not wait either.
        let pipe = root.join("pipe");
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = sender.send(content_hash(&pipe, 0));
        });
        assert_eq!(receiver.recv_timeout(Duration::from_secs(10)), Ok(None));
    }

    #[cfg(unix)]
    #[test]
    fn a_link_made_just_now_is_not_read() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        fs::write(root.join("small"), "small").unwrap();
        fs::write(root.join("large"), vec![0u8; 2 * HASH_LIMIT as usize]).unwrap();
        let now = SystemTime::now();
        for target in ["small", "large", "/dev/zero"] {
            let link = root.join(format!("link-{}", target.replace('/', "-")));
            std::os::unix::fs::symlink(root.join(target), &link).unwrap();
            let metadata = fs::symlink_metadata(&link).unwrap();
            assert_eq!(Stamp::of(&link, &metadata, now).hash, None, "{target}");
            assert_eq!(content_hash(&link, metadata.len()), None, "{target}");
        }
        assert!(content_hash(&root.join("small"), 5).is_some());
    }

    #[test]
    fn a_file_that_grew_past_the_limit_is_not_hashed() {
        let root = tempfile::tempdir().unwrap();
        let file = root.path().join("grown");
        fs::write(&file, vec![0u8; HASH_LIMIT as usize + 1]).unwrap();
        // The size taken before the file grew.
        assert_eq!(content_hash(&file, 10), None);
        fs::write(&file, vec![0u8; HASH_LIMIT as usize]).unwrap();
        assert!(content_hash(&file, 10).is_some());
    }

    #[cfg(unix)]
    #[test]
    fn a_folder_that_becomes_readable_is_watched() {
        use std::os::unix::fs::PermissionsExt;
        if unsafe { libc::geteuid() } == 0 {
            return;
        }
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let locked = root.join("locked");
        fs::create_dir(&locked).unwrap();
        fs::write(locked.join("a.roc"), "a").unwrap();
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
        let watcher = Watcher::start(tree_config(&root, None));
        fs::set_permissions(&locked, fs::Permissions::from_mode(0o755)).unwrap();
        let mut watcher = watcher.unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("locked/a.roc".to_owned(), ChangeKind::Created)]
        );

        fs::write(locked.join("b.roc"), "b").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &root),
            [("locked/b.roc".to_owned(), ChangeKind::Created)]
        );
    }

    /// A chain of folders whose deepest path is longer than Linux allows,
    /// built from the bottom up so that every path it names stays short.
    #[cfg(target_os = "linux")]
    fn too_deep(top: &Path) -> PathBuf {
        let chain = top.join("chain");
        let step = top.join("step");
        fs::create_dir(&chain).unwrap();
        for _ in 0..20 {
            fs::create_dir(&step).unwrap();
            fs::rename(&chain, step.join("d".repeat(250))).unwrap();
            fs::rename(&step, &chain).unwrap();
        }
        chain
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn a_failed_set_keeps_the_watches_it_had() {
        let parent = tempfile::tempdir().unwrap();
        let parent = parent.path().canonicalize().unwrap();
        let kept = parent.join("kept");
        fs::create_dir(&kept).unwrap();
        fs::write(kept.join("a.roc"), "a").unwrap();
        let deep = too_deep(&parent);
        let mut watcher = Watcher::start(tree_config(&kept, None)).unwrap();

        // Watching the folder too deep to name fails after the watches on
        // `kept` were dropped.
        assert!(matches!(
            watcher.set(tree_config(&deep, None)),
            Err(Error::Io(_))
        ));
        // Let the rescan the failure asked for pass, so what follows is
        // found by the watch alone.
        assert!(watcher
            .next(Duration::from_millis(200), Duration::from_millis(10))
            .unwrap()
            .is_empty());

        fs::write(kept.join("a.roc"), "a, edited").unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 1), &kept),
            [("a.roc".to_owned(), ChangeKind::Modified)]
        );
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn an_error_in_next_loses_no_changes() {
        let parent = tempfile::tempdir().unwrap();
        let parent = parent.path().canonicalize().unwrap();
        let root = parent.join("root");
        fs::create_dir_all(root.join("sub")).unwrap();
        fs::write(root.join("a.roc"), "a").unwrap();
        fs::write(root.join("sub/b.roc"), "b").unwrap();
        let deep = too_deep(&parent);
        let mut watcher = Watcher::start(tree_config(&root, None)).unwrap();

        // Two edits and a folder too deep to watch arrive in one burst. The
        // root is looked at first, and watching the new folder in it fails
        // after the edit there was seen and before `sub` was looked at.
        fs::write(root.join("a.roc"), "a, edited").unwrap();
        fs::write(root.join("sub/b.roc"), "b, edited").unwrap();
        fs::rename(&deep, root.join("chain")).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        assert!(matches!(
            watcher.next(Duration::from_secs(2), Duration::from_millis(50)),
            Err(Error::Io(_))
        ));

        // The calls after the error report both edits, as edits.
        fs::rename(root.join("chain"), parent.join("chain")).unwrap();
        assert_eq!(
            kinds(collect(&mut watcher, 2), &root),
            [
                ("a.roc".to_owned(), ChangeKind::Modified),
                ("sub/b.roc".to_owned(), ChangeKind::Modified)
            ]
        );
    }

    #[test]
    fn events_inside_a_skipped_folder_are_dropped() {
        let shared = Shared::default();
        *shared.skipping() = Skipping {
            roots: vec![
                (PathBuf::from("/tree"), true),
                (PathBuf::from("/flat"), false),
            ],
            names: vec![OsString::from(".git")],
        };
        let event = |path: &str| {
            Ok(
                notify::Event::new(notify::EventKind::Create(notify::event::CreateKind::Any))
                    .add_path(PathBuf::from(path)),
            )
        };
        shared.note(event("/tree/.git/objects/ab"));
        shared.note(event("/tree/src/.git/HEAD"));
        {
            let pending = shared.lock();
            assert!(pending.dirty.is_empty());
            assert_eq!(pending.last_event, None);
        }
        for path in [
            "/tree/.git",
            "/tree/src/a.roc",
            "/flat/.git/HEAD",
            "/elsewhere/.git/HEAD",
        ] {
            shared.note(event(path));
            assert!(shared.lock().dirty.contains(Path::new(path)), "{path}");
        }
    }

    /// Restarting the FSEvents stream to watch a root again drops events under
    /// the other roots, so those are compared too.
    #[cfg(target_os = "macos")]
    #[test]
    fn a_root_watched_again_compares_the_other_roots() {
        let parent = tempfile::tempdir().unwrap();
        let parent = parent.path().canonicalize().unwrap();
        let (one, two) = (parent.join("one"), parent.join("two"));
        fs::create_dir(&one).unwrap();
        fs::create_dir(&two).unwrap();
        let mut watcher = Watcher::start(Config {
            folders: Vec::new(),
            trees: vec![one.clone(), two.clone()],
            skip: Vec::new(),
            poll: None,
        })
        .unwrap();
        // Events go to the old Shared from now on, as if the stream dropped
        // them, and `one` looks replaced.
        watcher.shared = Arc::new(Shared::default());
        fs::write(two.join("b.roc"), "b").unwrap();
        {
            let mut pending = watcher.shared.lock();
            pending.replaced.insert(one.clone());
            pending.last_event = Some(Instant::now());
        }
        assert_eq!(
            kinds(
                watcher
                    .next(Duration::from_millis(500), Duration::from_millis(10))
                    .unwrap(),
                &parent
            ),
            [("two/b.roc".to_owned(), ChangeKind::Created)]
        );
    }
}
