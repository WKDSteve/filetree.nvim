//! Watch a folder tree and say which folders' listings changed.
//!
//! One recursive watch per root on every system (`notify`: ReadDirectoryChangesW, FSEvents, and on
//! Linux one inotify watch per folder, added for new folders as they appear). Reports what
//! `filetree.native.fs.watch` reports: the folders in which an entry came, went or was renamed, a
//! short quiet after the events.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use notify::event::{EventKind, ModifyKind};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use crate::paths;

/// Quiet time before the changed folders are reported.
const QUIET: Duration = Duration::from_millis(100);
/// The longest a report waits for the quiet: a folder that changes all the time is still reported.
const LONGEST: Duration = Duration::from_secs(1);

/// A running watch; dropping it ends it.
pub struct Watch {
    _watcher: RecommendedWatcher,
}

/// Watch `root`; `report` gets the changed folders (normalized, sorted) from a thread of its own.
pub fn start(root: &str, report: impl Fn(Vec<String>) + Send + 'static) -> notify::Result<Watch> {
    let (events, queue) = mpsc::channel::<String>();
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        let Ok(event) = event else { return };
        // A listing changes when an entry comes, goes or is renamed; a changed content is not one.
        let listing = matches!(
            event.kind,
            EventKind::Create(_) | EventKind::Remove(_) | EventKind::Modify(ModifyKind::Name(_))
        );
        if !listing {
            return;
        }
        for path in &event.paths {
            let path = paths::norm(path);
            if let Some(dir) = paths::parent(&path) {
                let _ = events.send(dir.to_owned());
            }
        }
    })?;
    watcher.watch(Path::new(root), RecursiveMode::Recursive)?;

    // ends when the watcher (the only sender) is dropped
    thread::spawn(move || {
        while let Some(dirs) = gather(&queue, QUIET, LONGEST) {
            report(dirs);
        }
    });
    Ok(Watch { _watcher: watcher })
}

/// The folders of the next report: from the first event until `quiet` passed without one, but never
/// longer than `longest` (a steady stream of events would otherwise never be reported). `None` when
/// the watch ended.
fn gather(queue: &Receiver<String>, quiet: Duration, longest: Duration) -> Option<Vec<String>> {
    let first = queue.recv().ok()?;
    let until = Instant::now() + longest;
    let mut dirs = BTreeSet::from([first]);
    loop {
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        match queue.recv_timeout(quiet.min(left)) {
            Ok(dir) => {
                dirs.insert(dir);
            }
            Err(RecvTimeoutError::Timeout) => break,
            Err(RecvTimeoutError::Disconnected) => return None,
        }
    }
    Some(dirs.into_iter().collect())
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let dirs = gather(
            &queue,
            Duration::from_millis(100),
            Duration::from_millis(250),
        )
        .expect("a report while the stream goes on");
        assert!(started.elapsed() < Duration::from_millis(600));
        assert_eq!(dirs, vec!["/r/d0", "/r/d1", "/r/d2"]);
        feeder.join().unwrap();
    }

    #[test]
    fn a_quiet_ends_the_report_early() {
        let (events, queue) = mpsc::channel::<String>();
        events.send("/r/a".to_owned()).unwrap();
        let started = Instant::now();
        let dirs = gather(&queue, Duration::from_millis(50), Duration::from_secs(5)).unwrap();
        assert_eq!(dirs, vec!["/r/a"]);
        assert!(started.elapsed() < Duration::from_secs(1));
        drop(events);
        assert!(gather(&queue, Duration::from_millis(50), Duration::from_secs(5)).is_none());
    }
}
