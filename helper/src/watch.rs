//! Watch a folder tree and say which folders' listings changed.
//!
//! Windows and macOS: one recursive watch per root (`notify`: ReadDirectoryChangesW, FSEvents).
//!
//! Linux: inotify has no recursive watch, and a watch per folder below the root runs into
//! `fs.inotify.max_user_watches` as soon as a `node_modules` or `target` lies there. So the folders
//! are watched one by one, and only the ones the deep listing would walk into (`walk::rules`: never
//! `.git`, nothing an ignore file names). A folder that appears is found by walking its parent again
//! with the same rules, and an ignore file that changes has the folders below it walked again. A
//! folder outside the rules that the tree reads all the same (an ignored one the user opened) is
//! named with `follow` and gets a watch of its own, for itself alone.
//!
//! Reports what `filetree.native.fs.watch` reports: the folders in which an entry came, went or was
//! renamed, a short quiet after the events.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use notify::event::{AccessKind, AccessMode, CreateKind, EventKind, ModifyKind, RenameMode};
use notify::{ErrorKind, RecommendedWatcher, RecursiveMode, Watcher};

use crate::{paths, walk};

/// Quiet time before the changed folders are reported.
const QUIET: Duration = Duration::from_millis(100);
/// The longest a report waits for the quiet: a folder that changes all the time is still reported.
const LONGEST: Duration = Duration::from_secs(1);

/// Is the tree watched folder by folder (true) or with one recursive watch (false)?
pub const PER_FOLDER: bool = cfg!(target_os = "linux");

/// What a watch says, from a thread of its own.
#[derive(Debug, PartialEq)]
pub enum Report {
    /// The watch stands: from now on every change is reported.
    Watching,
    /// The folders whose listing changed (normalized, sorted).
    Changed(Vec<String>),
    /// It cannot watch (any more): the root is not there, or the system has no watch left.
    Failed(String),
}

enum Message {
    Event(notify::Event),
    Follow(PathBuf),
    Stop,
}

/// A running watch; dropping it ends it.
pub struct Watch {
    messages: Sender<Message>,
}

impl Watch {
    /// Watch `dir` itself too, whatever the ignore rules say about it (the tree reads it). Nothing
    /// where the watch is recursive anyway.
    pub fn follow(&self, dir: &str) {
        let _ = self.messages.send(Message::Follow(clean(dir)));
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        let _ = self.messages.send(Message::Stop);
    }
}

/// Watch `root`; `report` is called from a thread of its own.
pub fn start(root: &str, report: impl Fn(Report) + Send + 'static) -> Watch {
    start_as(root, PER_FOLDER, report)
}

fn start_as(root: &str, per_folder: bool, report: impl Fn(Report) + Send + 'static) -> Watch {
    let (messages, queue) = mpsc::channel::<Message>();
    let events = messages.clone();
    let root = clean(root);
    thread::spawn(move || {
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            let Ok(event) = event else { return };
            // a file that was written matters only when it is an ignore file
            let rules = written(&event.kind) && event.paths.iter().any(|path| rules_file(path));
            if listing(&event.kind) || event.need_rescan() || rules {
                let _ = events.send(Message::Event(event));
            }
        });
        let watcher = match watcher {
            Ok(watcher) => watcher,
            Err(err) => return report(Report::Failed(err.to_string())),
        };
        Worker {
            root,
            per_folder,
            watcher,
            folders: Folders::default(),
        }
        .run(&queue, &report);
    });
    Watch { messages }
}

/// A listing changes when an entry comes, goes or is renamed; a changed content is not one.
fn listing(kind: &EventKind) -> bool {
    matches!(
        kind,
        EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(ModifyKind::Name(_))
    )
}

/// A file was written and closed (said on Linux only): what an ignore file needs to be read again.
fn written(kind: &EventKind) -> bool {
    matches!(
        kind,
        EventKind::Access(AccessKind::Close(AccessMode::Write))
    )
}

/// Does this file decide what the walk leaves out? (`.git/info/exclude` and the user's global ignore
/// file do too; a change of those is not followed.)
fn rules_file(path: &Path) -> bool {
    path.file_name()
        .is_some_and(|name| name == ".gitignore" || name == ".ignore")
}

/// One spelling for a folder: no trailing separator, no `.` in it.
fn clean(dir: &str) -> PathBuf {
    Path::new(dir).components().collect()
}

/// The folders that are watched one by one.
#[derive(Default)]
struct Folders {
    /// Found by the rules of the walk, below the root. Shared with the filter of a walk in `scan`.
    tree: Arc<Mutex<BTreeSet<PathBuf>>>,
    /// Named by `follow` and outside the rules: watched for themselves, nothing below them.
    pinned: BTreeSet<PathBuf>,
    /// Everything `follow` named, inside the rules or not: stays watched when the rules change.
    named: BTreeSet<PathBuf>,
    /// What the last full scan did not find any more: gone, or left out by the rules now.
    stale: Vec<PathBuf>,
}

impl Folders {
    fn tree(&self) -> MutexGuard<'_, BTreeSet<PathBuf>> {
        self.tree
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Walk `start` with the rules of the deep listing and watch (`add`) every folder that is not
    /// watched yet; folders that are watched already are not walked into. `full`: walk into all of
    /// them and watch every one again (after events were lost: a folder may have gone and come back),
    /// and move the ones it does not find any more to `stale`. Returns the folders that are new.
    ///
    /// A folder is watched before it is read, so nothing made in it afterwards is missed. Fails when
    /// `start` itself cannot be watched, or the system has no watch left.
    fn scan(
        &mut self,
        start: &Path,
        full: bool,
        add: &mut dyn FnMut(&Path) -> notify::Result<()>,
    ) -> notify::Result<Vec<PathBuf>> {
        let mut new = Vec::new();
        let mut seen = BTreeSet::new();
        let mut builder = walk::rules(start);
        if !full {
            let watched = Arc::clone(&self.tree);
            builder.filter_entry(move |entry| {
                walk::kept(entry)
                    && (entry.depth() == 0
                        || !entry.file_type().is_some_and(|kind| kind.is_dir())
                        || !watched
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner())
                            .contains(entry.path()))
            });
        }
        for entry in builder.build() {
            let Ok(entry) = entry else { continue };
            let dir = entry.path();
            // a root that is a link to a folder is a folder here, as it is for the walk
            let folder = entry.file_type().is_some_and(|kind| kind.is_dir())
                || (entry.depth() == 0 && dir.is_dir());
            if !folder {
                continue;
            }
            let known = self.tree().contains(dir);
            if known && !full {
                // `start` itself
                continue;
            }
            // watched for itself until now: one of the tree from here on, with what lies below it
            let pinned = self.pinned.remove(dir);
            if !pinned || full {
                match add(dir) {
                    Ok(()) => {}
                    Err(err)
                        if entry.depth() == 0 || matches!(err.kind, ErrorKind::MaxFilesWatch) =>
                    {
                        return Err(err);
                    }
                    // gone again, or not ours to read (then the walk finds nothing below it either)
                    Err(_) => continue,
                }
            }
            if full {
                seen.insert(dir.to_path_buf());
            }
            if !known {
                self.tree().insert(dir.to_path_buf());
                if !pinned {
                    new.push(dir.to_path_buf());
                }
            }
        }
        if full {
            let mut stale = Vec::new();
            self.tree().retain(|dir| {
                let keep = seen.contains(dir) || !dir.starts_with(start);
                if !keep {
                    stale.push(dir.clone());
                }
                keep
            });
            self.stale.extend(stale);
        }
        Ok(new)
    }

    /// `path` is gone (deleted or moved away): it and everything below it is not watched any more.
    /// `notify` drops its watches on the same events.
    fn forget(&mut self, path: &Path) {
        fn drop_below(set: &mut BTreeSet<PathBuf>, path: &Path) {
            let below: Vec<PathBuf> = set
                .range(path.to_path_buf()..)
                .take_while(|dir| dir.starts_with(path))
                .cloned()
                .collect();
            for dir in below {
                set.remove(&dir);
            }
        }
        drop_below(&mut self.tree(), path);
        drop_below(&mut self.pinned, path);
        drop_below(&mut self.named, path);
    }
}

/// What the events of one report add up to.
#[derive(Default)]
struct Batch {
    /// Folders whose listing changed.
    dirty: BTreeSet<String>,
    /// Watched folders in which a folder appeared: walked again when the batch is complete.
    rescan: BTreeSet<PathBuf>,
    /// Watched folders whose ignore file changed: everything below them is walked again.
    rules: BTreeSet<PathBuf>,
    /// Events were lost: everything is walked again.
    lost: bool,
    failed: Option<String>,
}

struct Worker {
    root: PathBuf,
    per_folder: bool,
    watcher: RecommendedWatcher,
    folders: Folders,
}

impl Worker {
    fn run(mut self, queue: &Receiver<Message>, report: &dyn Fn(Report)) {
        let started = if self.per_folder {
            let watcher = &mut self.watcher;
            self.folders
                .scan(&self.root, true, &mut |dir| {
                    watcher.watch(dir, RecursiveMode::NonRecursive)
                })
                .and_then(|_| {
                    // a root that is not there is walked without a word
                    if self.folders.tree().contains(&self.root) {
                        Ok(())
                    } else {
                        Err(notify::Error::path_not_found().add_path(self.root.clone()))
                    }
                })
        } else {
            self.watcher.watch(&self.root, RecursiveMode::Recursive)
        };
        if let Err(err) = started {
            return report(Report::Failed(err.to_string()));
        }
        report(Report::Watching);

        loop {
            let mut batch = Batch::default();
            let mut stopped = false;
            let open = gather(queue, QUIET, LONGEST, |message| match message {
                Message::Stop => {
                    stopped = true;
                    false
                }
                Message::Event(event) => {
                    self.note(&event, &mut batch);
                    true
                }
                Message::Follow(dir) => {
                    self.follow(dir, &mut batch);
                    true
                }
            });
            if stopped || !open {
                return;
            }
            self.catch_up(&mut batch);
            if !batch.dirty.is_empty() {
                report(Report::Changed(batch.dirty.into_iter().collect()));
            }
            if let Some(why) = batch.failed {
                report(Report::Failed(why));
            }
        }
    }

    /// One event: the folders whose listing changed, and what it means for the watched folders.
    fn note(&mut self, event: &notify::Event, batch: &mut Batch) {
        if event.need_rescan() {
            batch.lost = true;
            return;
        }
        let listing = listing(&event.kind);
        for (index, path) in event.paths.iter().enumerate() {
            if listing {
                if let Some(dir) = paths::parent(&paths::norm(path)) {
                    batch.dirty.insert(dir.to_owned());
                }
            }
            if !self.per_folder {
                continue;
            }
            if rules_file(path) {
                if let Some(parent) = path.parent() {
                    if self.folders.tree().contains(parent) {
                        batch.rules.insert(parent.to_path_buf());
                    }
                }
            }
            if !listing {
                continue;
            }
            // a rename names where from, where to, or both (from first)
            let (gone, came) = match event.kind {
                EventKind::Remove(_) => (true, false),
                EventKind::Create(CreateKind::File) => (false, false),
                EventKind::Create(_) => (false, true),
                EventKind::Modify(ModifyKind::Name(RenameMode::From)) => (true, false),
                EventKind::Modify(ModifyKind::Name(RenameMode::To)) => (false, true),
                EventKind::Modify(ModifyKind::Name(RenameMode::Both)) => (index == 0, index == 1),
                _ => (true, true),
            };
            if gone {
                self.folders.forget(path);
            }
            // a link to a folder is not walked into, as in the deep listing
            if came && std::fs::symlink_metadata(path).is_ok_and(|meta| meta.is_dir()) {
                if let Some(parent) = path.parent() {
                    if self.folders.tree().contains(parent) {
                        batch.rescan.insert(parent.to_path_buf());
                    }
                }
            }
        }
    }

    /// The tree reads `dir`: watch it, whatever the rules say about it.
    fn follow(&mut self, dir: PathBuf, batch: &mut Batch) {
        if !self.per_folder || !dir.starts_with(&self.root) || self.folders.named.contains(&dir) {
            return;
        }
        if self.folders.tree().contains(&dir) {
            self.folders.named.insert(dir);
            return;
        }
        match self.watcher.watch(&dir, RecursiveMode::NonRecursive) {
            Ok(()) => {
                // what came or went between the tree's reading and this watch: read once more
                batch.dirty.insert(paths::norm(&dir));
                self.folders.pinned.insert(dir.clone());
                self.folders.named.insert(dir);
            }
            Err(err) if matches!(err.kind, ErrorKind::MaxFilesWatch) => {
                batch.failed = Some(err.to_string());
            }
            // gone, or not a folder: nothing to watch
            Err(_) => {}
        }
    }

    /// Watch the folders that appeared during the batch. They count as changed: what was made in
    /// them before they were watched is in their listing by now.
    fn catch_up(&mut self, batch: &mut Batch) {
        let watcher = &mut self.watcher;
        let mut add = |dir: &Path| watcher.watch(dir, RecursiveMode::NonRecursive);
        if batch.lost && self.per_folder {
            // nobody knows what was missed: every folder is watched again and counts as changed
            batch.rescan.clear();
            batch.rules.clear();
            let named = &mut self.folders.named;
            self.folders.pinned.retain(|dir| {
                let there = add(dir).is_ok();
                if !there {
                    named.remove(dir);
                }
                there
            });
            if let Err(err) = self.folders.scan(&self.root, true, &mut add) {
                batch.failed = Some(err.to_string());
            }
            for dir in self.folders.tree().iter().chain(&self.folders.pinned) {
                batch.dirty.insert(paths::norm(dir));
            }
        }
        let mut walked: Option<PathBuf> = None;
        for dir in std::mem::take(&mut batch.rules) {
            // below a folder that was just walked in full (parents sort first)
            if walked.as_ref().is_some_and(|above| dir.starts_with(above))
                || !self.folders.tree().contains(&dir)
            {
                continue;
            }
            match self.folders.scan(&dir, true, &mut add) {
                Ok(new) => batch.dirty.extend(new.iter().map(|dir| paths::norm(dir))),
                Err(err) if matches!(err.kind, ErrorKind::MaxFilesWatch) => {
                    batch.failed = Some(err.to_string());
                    break;
                }
                Err(_) => {}
            }
            walked = Some(dir);
        }
        for parent in std::mem::take(&mut batch.rescan) {
            // forgotten later in the same batch: its parent was walked again, or it is gone
            if !self.folders.tree().contains(&parent) {
                continue;
            }
            match self.folders.scan(&parent, false, &mut add) {
                Ok(new) => batch.dirty.extend(new.iter().map(|dir| paths::norm(dir))),
                Err(err) if matches!(err.kind, ErrorKind::MaxFilesWatch) => {
                    batch.failed = Some(err.to_string());
                    break;
                }
                Err(_) => {}
            }
        }
        for dir in std::mem::take(&mut self.folders.stale) {
            // The tree reads it: watched for itself from here on, whatever the rules say now. Watched
            // again, because after lost events the folder may be another one than the one watched.
            let named = self.folders.named.contains(&dir);
            if named && (self.watcher.watch(&dir, RecursiveMode::NonRecursive)).is_ok() {
                self.folders.pinned.insert(dir);
            } else {
                self.folders.named.remove(&dir);
                let _ = self.watcher.unwatch(&dir);
            }
        }
    }
}

/// Hand the messages of the next report to `take`: from the first one until `quiet` passed without
/// one, but never longer than `longest` (a steady stream would otherwise never be reported), or until
/// `take` says false. False when the queue ended.
fn gather<T>(
    queue: &Receiver<T>,
    quiet: Duration,
    longest: Duration,
    mut take: impl FnMut(T) -> bool,
) -> bool {
    let Ok(first) = queue.recv() else {
        return false;
    };
    if !take(first) {
        return true;
    }
    let until = Instant::now() + longest;
    loop {
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return true;
        }
        match queue.recv_timeout(quiet.min(left)) {
            Ok(message) => {
                if !take(message) {
                    return true;
                }
            }
            Err(RecvTimeoutError::Timeout) => return true,
            Err(RecvTimeoutError::Disconnected) => return false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn a_steady_stream_is_reported_within_the_longest_wait() {
        let (events, queue) = mpsc::channel::<String>();
        let feeder = thread::spawn(move || {
            // an event every 20 ms for 1 s: never 100 ms of quiet
            for i in 0..50 {
                let _ = events.send(format!("/r/d{}", i % 3));
                thread::sleep(Duration::from_millis(20));
            }
        });
        let started = Instant::now();
        let mut dirs = BTreeSet::new();
        let open = gather(
            &queue,
            Duration::from_millis(100),
            Duration::from_millis(250),
            |dir| {
                dirs.insert(dir);
                true
            },
        );
        assert!(open, "a report while the stream goes on");
        assert!(started.elapsed() < Duration::from_millis(600));
        assert_eq!(
            dirs.into_iter().collect::<Vec<_>>(),
            vec!["/r/d0", "/r/d1", "/r/d2"]
        );
        feeder.join().unwrap();
    }

    #[test]
    fn a_quiet_ends_the_report_early() {
        let (events, queue) = mpsc::channel::<String>();
        events.send("/r/a".to_owned()).unwrap();
        let started = Instant::now();
        let mut dirs = Vec::new();
        let quiet = Duration::from_millis(50);
        assert!(gather(&queue, quiet, Duration::from_secs(5), |dir| {
            dirs.push(dir);
            true
        }));
        assert_eq!(dirs, vec!["/r/a"]);
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(events);
        assert!(!gather(&queue, quiet, Duration::from_secs(5), |_| true));
    }

    #[test]
    fn a_message_can_end_the_report() {
        let (events, queue) = mpsc::channel::<u8>();
        for n in [1, 2, 3] {
            events.send(n).unwrap();
        }
        let mut taken = Vec::new();
        let long = Duration::from_secs(5);
        assert!(gather(&queue, long, long, |n| {
            taken.push(n);
            n < 2
        }));
        assert_eq!(taken, vec![1, 2]);
    }

    /// A repository: `src/deep` and `docs` are walked, `target` (with 20 folders) and `.git` not.
    fn fixture(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("ft_helper_watch_{name}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("src/deep")).unwrap();
        fs::create_dir_all(dir.join("docs")).unwrap();
        fs::create_dir_all(dir.join(".git/objects")).unwrap();
        for n in 0..20 {
            fs::create_dir_all(dir.join(format!("target/debug/d{n}"))).unwrap();
        }
        fs::write(dir.join(".gitignore"), "target/\n/build/\n").unwrap();
        fs::write(dir.join("src/a.rs"), "").unwrap();
        // the spelling the walk hands back
        clean(&paths::norm(&dir))
    }

    fn names(root: &Path, dirs: impl IntoIterator<Item = PathBuf>) -> Vec<String> {
        let mut out: Vec<String> = dirs
            .into_iter()
            .map(|dir| paths::norm(dir.strip_prefix(root).unwrap()))
            .collect();
        out.sort();
        out
    }

    /// A stand-in for the watcher: remembers what it was asked to watch.
    fn recorder(log: &mut Vec<PathBuf>) -> impl FnMut(&Path) -> notify::Result<()> + '_ {
        |dir| {
            log.push(dir.to_path_buf());
            Ok(())
        }
    }

    #[test]
    fn the_first_scan_watches_what_the_walk_walks_into() {
        let root = fixture("first");
        let mut folders = Folders::default();
        let mut log = Vec::new();
        let new = folders.scan(&root, true, &mut recorder(&mut log)).unwrap();
        assert_eq!(names(&root, new), vec!["", "docs", "src", "src/deep"]);
        assert_eq!(log.len(), 4, "no watch for .git, target or anything in it");
        assert_eq!(folders.tree().len(), 4);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_scan_of_a_parent_finds_the_new_folders_and_only_them() {
        let root = fixture("parent");
        let mut folders = Folders::default();
        folders.scan(&root, true, &mut |_| Ok(())).unwrap();

        // made with everything in it at once, as `mkdir -p` or a move into the tree does
        fs::create_dir_all(root.join("src/new/inner")).unwrap();
        // ignored by a rule of the root that is anchored there, and by one that is not
        fs::create_dir_all(root.join("build/out")).unwrap();
        fs::create_dir_all(root.join("src/target/x")).unwrap();
        fs::create_dir_all(root.join("src/build")).unwrap();
        let mut log = Vec::new();
        let new = folders
            .scan(&root.join("src"), false, &mut recorder(&mut log))
            .unwrap();
        assert_eq!(
            names(&root, new),
            vec!["src/build", "src/new", "src/new/inner"]
        );
        assert_eq!(log.len(), 3, "src and src/deep are watched already");

        let mut log = Vec::new();
        let new = folders.scan(&root, false, &mut recorder(&mut log)).unwrap();
        assert!(new.is_empty(), "build/ is ignored: {new:?}");
        assert!(log.is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_followed_folder_is_watched_alone_until_the_rules_reach_it() {
        let root = fixture("pinned");
        let mut folders = Folders::default();
        folders.scan(&root, true, &mut |_| Ok(())).unwrap();

        // the tree read src/fresh before the scan of src came to it
        fs::create_dir_all(root.join("src/fresh/sub")).unwrap();
        folders.pinned.insert(root.join("src/fresh"));
        folders.pinned.insert(root.join("target"));
        let mut log = Vec::new();
        let new = folders
            .scan(&root.join("src"), false, &mut recorder(&mut log))
            .unwrap();
        assert_eq!(names(&root, new), vec!["src/fresh/sub"]);
        assert_eq!(
            names(&root, log),
            vec!["src/fresh/sub"],
            "not watched twice"
        );
        assert!(folders.tree().contains(&root.join("src/fresh")));
        assert_eq!(names(&root, folders.pinned.clone()), vec!["target"]);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_folder_that_went_is_forgotten_with_what_was_below_it() {
        let root = fixture("forget");
        let mut folders = Folders::default();
        folders.scan(&root, true, &mut |_| Ok(())).unwrap();
        fs::create_dir_all(root.join("src2")).unwrap();
        folders.scan(&root, false, &mut |_| Ok(())).unwrap();
        folders.pinned.insert(root.join("src/deep/ignored"));
        folders.named.insert(root.join("src/deep/ignored"));
        folders.named.insert(root.join("src/deep"));

        folders.forget(&root.join("src"));
        assert_eq!(
            names(&root, folders.tree().clone()),
            vec!["", "docs", "src2"]
        );
        assert!(folders.pinned.is_empty());
        assert!(folders.named.is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_full_scan_watches_everything_again_and_drops_what_is_gone() {
        let root = fixture("full");
        let mut folders = Folders::default();
        folders.scan(&root, true, &mut |_| Ok(())).unwrap();
        fs::remove_dir_all(root.join("src/deep")).unwrap();
        fs::create_dir_all(root.join("docs/more")).unwrap();
        let mut log = Vec::new();
        let new = folders.scan(&root, true, &mut recorder(&mut log)).unwrap();
        assert_eq!(names(&root, new), vec!["docs/more"]);
        assert_eq!(names(&root, log), vec!["", "docs", "docs/more", "src"]);
        assert_eq!(
            names(&root, folders.tree().clone()),
            vec!["", "docs", "docs/more", "src"]
        );
        assert_eq!(names(&root, folders.stale.clone()), vec!["src/deep"]);

        // the rules change: what they leave out now is stale, what they let in is new
        fs::write(root.join(".gitignore"), "docs/\n").unwrap();
        folders.stale.clear();
        let new = folders.scan(&root, true, &mut |_| Ok(())).unwrap();
        assert_eq!(
            new.len(),
            22,
            "target, target/debug and the 20 folders in it"
        );
        assert_eq!(
            names(&root, folders.stale.clone()),
            vec!["docs", "docs/more"]
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn a_scan_ends_when_the_system_has_no_watch_left() {
        let root = fixture("limit");
        let mut folders = Folders::default();
        let mut left = 2;
        let err = folders
            .scan(&root, true, &mut |_| {
                if left == 0 {
                    return Err(notify::Error::new(ErrorKind::MaxFilesWatch));
                }
                left -= 1;
                Ok(())
            })
            .unwrap_err();
        assert!(matches!(err.kind, ErrorKind::MaxFilesWatch));

        // a folder that cannot be watched for another reason is left out, and tried again by the
        // next scan of its parent
        let mut folders = Folders::default();
        let src = root.join("src");
        let new = folders
            .scan(&root, true, &mut |dir| {
                if dir == src {
                    return Err(notify::Error::path_not_found());
                }
                Ok(())
            })
            .unwrap();
        assert_eq!(names(&root, new), vec!["", "docs", "src/deep"]);
        assert!(!folders.tree().contains(&src));
        let _ = fs::remove_dir_all(&root);
    }

    /// The real thing, folder by folder. Linux only: there it is used, and a watch per folder holds
    /// the folder open on Windows.
    #[cfg(target_os = "linux")]
    mod per_folder {
        use super::*;

        /// The reports of a watch, until `want` is among the changed folders (or 5 s passed).
        fn changed_until(reports: &Receiver<Report>, want: &Path) -> Vec<String> {
            let want = paths::norm(want);
            let until = Instant::now() + Duration::from_secs(5);
            let mut all = Vec::new();
            while let Ok(report) =
                reports.recv_timeout(until.saturating_duration_since(Instant::now()))
            {
                if let Report::Changed(dirs) = report {
                    all.extend(dirs);
                    if all.contains(&want) {
                        break;
                    }
                }
            }
            all
        }

        fn watch(root: &Path) -> (Watch, Receiver<Report>) {
            let (sender, reports) = mpsc::channel();
            let watch = start_as(root.to_str().unwrap(), true, move |report| {
                let _ = sender.send(report);
            });
            assert_eq!(
                reports.recv_timeout(Duration::from_secs(5)),
                Ok(Report::Watching)
            );
            (watch, reports)
        }

        /// `inotify_watches` counts every watch of this process: one test of this module at a time.
        static ONE_AT_A_TIME: std::sync::Mutex<()> = std::sync::Mutex::new(());

        fn inotify_watches() -> usize {
            let mut count = 0;
            for fd in fs::read_dir("/proc/self/fdinfo").unwrap().flatten() {
                if let Ok(text) = fs::read_to_string(fd.path()) {
                    count += text
                        .lines()
                        .filter(|line| line.starts_with("inotify wd:"))
                        .count();
                }
            }
            count
        }

        #[test]
        fn an_ignored_folder_costs_no_watch_and_a_new_folder_is_followed() {
            let _one = ONE_AT_A_TIME
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let root = fixture("real");
            let before = inotify_watches();
            let (watch, reports) = watch(&root);
            assert_eq!(inotify_watches() - before, 4, "root, docs, src, src/deep");

            // a change in a folder nobody opened
            fs::write(root.join("src/deep/b.rs"), "").unwrap();
            let all = changed_until(&reports, &root.join("src/deep"));
            assert!(
                all.contains(&paths::norm(&root.join("src/deep"))),
                "{all:?}"
            );

            // a folder made later, with a folder in it; then a file in that one
            fs::create_dir_all(root.join("docs/later/sub")).unwrap();
            let all = changed_until(&reports, &root.join("docs/later/sub"));
            assert!(all.contains(&paths::norm(&root.join("docs"))), "{all:?}");
            assert_eq!(inotify_watches() - before, 6);
            fs::write(root.join("docs/later/sub/new.md"), "").unwrap();
            let all = changed_until(&reports, &root.join("docs/later/sub"));
            assert!(
                all.contains(&paths::norm(&root.join("docs/later/sub"))),
                "{all:?}"
            );

            // an ignored folder made later is not watched, and a file in it is not reported
            fs::create_dir_all(root.join("build/out")).unwrap();
            let all = changed_until(&reports, &root);
            assert!(all.contains(&paths::norm(&root)), "{all:?}");
            fs::write(root.join("build/out/x.o"), "").unwrap();
            fs::write(root.join("target/debug/d1/x.o"), "").unwrap();
            fs::write(root.join("docs/marker.md"), "").unwrap();
            let all = changed_until(&reports, &root.join("docs"));
            assert!(
                !all.iter()
                    .any(|dir| dir.contains("/build") || dir.contains("/target")),
                "{all:?}"
            );
            assert_eq!(inotify_watches() - before, 6);

            // ... until the tree reads it: then it is watched, for itself alone
            watch.follow(root.join("target/debug").to_str().unwrap());
            let all = changed_until(&reports, &root.join("target/debug"));
            assert!(
                all.contains(&paths::norm(&root.join("target/debug"))),
                "{all:?}"
            );
            assert_eq!(inotify_watches() - before, 7);
            fs::create_dir_all(root.join("target/debug/d99/deeper")).unwrap();
            let all = changed_until(&reports, &root.join("target/debug"));
            assert!(
                all.contains(&paths::norm(&root.join("target/debug"))),
                "{all:?}"
            );
            thread::sleep(Duration::from_millis(300));
            assert_eq!(
                inotify_watches() - before,
                7,
                "nothing below a followed folder"
            );

            // a folder that moves away is not watched any more; moved back in, it is again
            let outside = root.with_extension("moved");
            let _ = fs::remove_dir_all(&outside);
            fs::rename(root.join("docs/later"), &outside).unwrap();
            let all = changed_until(&reports, &root.join("docs"));
            assert!(all.contains(&paths::norm(&root.join("docs"))), "{all:?}");
            assert_eq!(inotify_watches() - before, 5);
            fs::write(outside.join("sub/unseen.md"), "").unwrap();
            fs::rename(&outside, root.join("src/back")).unwrap();
            let all = changed_until(&reports, &root.join("src/back/sub"));
            assert!(
                all.contains(&paths::norm(&root.join("src/back/sub"))),
                "{all:?}"
            );
            assert_eq!(inotify_watches() - before, 7);

            // an ignore file changes: the folders are watched by the new rules. docs is left out
            // now, src/back/sub too; src/deep was named by the tree and stays for itself
            watch.follow(root.join("src/deep").to_str().unwrap());
            fs::write(root.join("src/.gitignore"), "back/sub/\ndeep/\n").unwrap();
            fs::write(root.join(".gitignore"), "target/\n/build/\n/docs/\n").unwrap();
            let until = Instant::now() + Duration::from_secs(5);
            while inotify_watches() - before != 5 && Instant::now() < until {
                thread::sleep(Duration::from_millis(20));
            }
            assert_eq!(
                inotify_watches() - before,
                5,
                "root, src, src/back, src/deep (named), target/debug (named)"
            );
            fs::write(root.join("src/deep/still.rs"), "").unwrap();
            let all = changed_until(&reports, &root.join("src/deep"));
            assert!(
                all.contains(&paths::norm(&root.join("src/deep"))),
                "{all:?}"
            );
            // ... and back: what the rules let in again is watched again
            fs::write(root.join(".gitignore"), "target/\n").unwrap();
            let all = changed_until(&reports, &root.join("build/out"));
            assert!(all.contains(&paths::norm(&root.join("docs"))), "{all:?}");
            assert_eq!(
                inotify_watches() - before,
                8,
                "docs, build and build/out came"
            );

            drop(watch);
            let until = Instant::now() + Duration::from_secs(5);
            while inotify_watches() != before && Instant::now() < until {
                thread::sleep(Duration::from_millis(20));
            }
            assert_eq!(
                inotify_watches(),
                before,
                "a dropped watch gives everything back"
            );
            let _ = fs::remove_dir_all(&root);
        }

        #[test]
        fn a_root_that_is_not_there_fails() {
            let _one = ONE_AT_A_TIME
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            let (sender, reports) = mpsc::channel();
            let _watch = start_as("/nonexistent/ft_helper_watch", true, move |report| {
                let _ = sender.send(report);
            });
            let report = reports.recv_timeout(Duration::from_secs(5)).unwrap();
            assert!(matches!(report, Report::Failed(_)), "{report:?}");
        }
    }
}
