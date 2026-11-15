//! Watch a folder tree and say which folders' listings changed.
//!
//! One recursive watch per root on every system (`notify`: ReadDirectoryChangesW, FSEvents, and on
//! Linux one inotify watch per folder, added for new folders as they appear). Reports what
//! `filetree.native.fs.watch` reports: the folders in which an entry came, went or was renamed, a
//! short quiet after the events.

use std::collections::BTreeSet;
use std::path::Path;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::Duration;

use notify::event::{EventKind, ModifyKind};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};

use crate::paths;

/// Quiet time before the changed folders are reported.
const QUIET: Duration = Duration::from_millis(100);

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
        while let Ok(first) = queue.recv() {
            let mut dirs = BTreeSet::from([first]);
            loop {
                match queue.recv_timeout(QUIET) {
                    Ok(dir) => {
                        dirs.insert(dir);
                    }
                    Err(RecvTimeoutError::Timeout) => break,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            }
            report(dirs.into_iter().collect());
        }
    });
    Ok(Watch { _watcher: watcher })
}
