//! Every file below a folder, in batches, with the ignore rules of `rg` (the `ignore` crate); and the
//! size of a folder with everything in it.
//!
//! `run` lists what `filetree.native.fs.deep` lists through `fd`: files, hidden ones too, never
//! `.git`, nothing an ignore file names; a link to a file (or a broken link) is a file, a link to a
//! folder is neither listed nor followed.
//!
//! `size` counts what `du` counts: every file, ignored ones and `.git` too; links are not followed.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use ignore::{DirEntry, Error, ParallelVisitor, ParallelVisitorBuilder, WalkBuilder, WalkState};

use crate::paths;

/// How many paths go into one message.
const BATCH: usize = 1000;

pub struct Summary {
    /// False when the walk was cancelled.
    pub ok: bool,
    pub files: u64,
}

struct Shared<'a> {
    cancel: &'a AtomicBool,
    sink: &'a (dyn Fn(Vec<String>) + Sync),
    files: AtomicU64,
}

struct Builder<'a> {
    shared: &'a Shared<'a>,
}

impl<'s> ParallelVisitorBuilder<'s> for Builder<'s> {
    fn build(&mut self) -> Box<dyn ParallelVisitor + 's> {
        Box::new(Visitor {
            shared: self.shared,
            batch: Vec::with_capacity(BATCH),
        })
    }
}

struct Visitor<'a> {
    shared: &'a Shared<'a>,
    batch: Vec<String>,
}

impl Visitor<'_> {
    fn flush(&mut self) {
        if self.batch.is_empty() {
            return;
        }
        let batch = std::mem::replace(&mut self.batch, Vec::with_capacity(BATCH));
        self.shared
            .files
            .fetch_add(batch.len() as u64, Ordering::Relaxed);
        (self.shared.sink)(batch);
    }
}

impl ParallelVisitor for Visitor<'_> {
    fn visit(&mut self, entry: Result<DirEntry, Error>) -> WalkState {
        if self.shared.cancel.load(Ordering::Relaxed) {
            self.batch.clear();
            return WalkState::Quit;
        }
        // a folder that cannot be read is left out, as `fd` leaves it out
        let Ok(entry) = entry else {
            return WalkState::Continue;
        };
        let Some(kind) = entry.file_type() else {
            return WalkState::Continue;
        };
        if kind.is_dir() {
            return WalkState::Continue;
        }
        if kind.is_symlink() && std::fs::metadata(entry.path()).is_ok_and(|target| target.is_dir())
        {
            return WalkState::Continue;
        }
        self.batch.push(paths::norm(entry.path()));
        if self.batch.len() >= BATCH {
            self.flush();
        }
        WalkState::Continue
    }
}

impl Drop for Visitor<'_> {
    fn drop(&mut self) {
        // the rest of this thread's paths, when the walk ends
        if !self.shared.cancel.load(Ordering::Relaxed) {
            self.flush();
        }
    }
}

/// What the deep listing walks into below `root`: hidden entries too, never `.git`, nothing an ignore
/// file names, no link followed. The watch uses the same rules for the folders it watches.
pub fn rules(root: impl AsRef<Path>) -> WalkBuilder {
    let mut builder = WalkBuilder::new(root);
    builder.hidden(false).follow_links(false).filter_entry(kept);
    builder
}

/// The entries `rules` leaves out by name (its `filter_entry`: setting another one replaces it).
pub fn kept(entry: &DirEntry) -> bool {
    entry.file_name() != ".git"
}

/// List every file below `root`; `sink` gets the batches, from several threads.
pub fn run(root: &str, cancel: &AtomicBool, sink: &(dyn Fn(Vec<String>) + Sync)) -> Summary {
    let shared = Shared {
        cancel,
        sink,
        files: AtomicU64::new(0),
    };
    rules(root)
        .build_parallel()
        .visit(&mut Builder { shared: &shared });
    Summary {
        ok: !cancel.load(Ordering::Relaxed),
        files: shared.files.load(Ordering::Relaxed),
    }
}

/// The number of files below `root` and the sum of their sizes, everything counted.
pub fn size(root: &str) -> (u64, u64) {
    let files = AtomicU64::new(0);
    let bytes = AtomicU64::new(0);
    WalkBuilder::new(root)
        .standard_filters(false)
        .follow_links(false)
        .build_parallel()
        .run(|| {
            Box::new(|entry| {
                let Ok(entry) = entry else {
                    return WalkState::Continue;
                };
                if entry.file_type().is_some_and(|kind| !kind.is_dir()) {
                    // a link is counted as itself (its own size), as `du` counts it
                    if let Ok(meta) = entry.metadata() {
                        files.fetch_add(1, Ordering::Relaxed);
                        bytes.fetch_add(meta.len(), Ordering::Relaxed);
                    }
                }
                WalkState::Continue
            })
        });
    (files.into_inner(), bytes.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::Mutex;

    fn fixture(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("ft_helper_walk_{name}_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("sub/deep")).unwrap();
        fs::create_dir_all(dir.join("ignored")).unwrap();
        fs::create_dir_all(dir.join(".git")).unwrap();
        fs::write(dir.join(".gitignore"), "ignored/\n").unwrap();
        fs::write(dir.join("a.txt"), "12345").unwrap();
        fs::write(dir.join("sub/deep/b.txt"), "123").unwrap();
        fs::write(dir.join("ignored/c.txt"), "1234567").unwrap();
        fs::write(dir.join(".git/HEAD"), "ref").unwrap();
        dir
    }

    #[test]
    fn the_listing_leaves_out_git_and_what_is_ignored() {
        let dir = fixture("list");
        let found = Mutex::new(Vec::new());
        let cancel = AtomicBool::new(false);
        // `.gitignore` counts inside a repository only, as for `fd` and `rg`
        let summary = run(dir.to_str().unwrap(), &cancel, &|batch| {
            found.lock().unwrap().extend(batch)
        });
        let mut found = found.into_inner().unwrap();
        found.sort();
        let base = paths::norm(&dir);
        assert!(summary.ok);
        assert!(found.contains(&format!("{base}/a.txt")));
        assert!(found.contains(&format!("{base}/sub/deep/b.txt")));
        assert!(found.contains(&format!("{base}/.gitignore")));
        assert!(!found.iter().any(|path| path.contains("/.git/")));
        assert!(!found.iter().any(|path| path.contains("/ignored/")));
        assert_eq!(summary.files, 3);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_size_counts_everything() {
        let dir = fixture("size");
        let (files, bytes) = size(dir.to_str().unwrap());
        // a.txt 5, b.txt 3, c.txt 7, .gitignore 9, .git/HEAD 3
        assert_eq!(files, 5);
        assert_eq!(bytes, 5 + 3 + 7 + 9 + 3);
        let _ = fs::remove_dir_all(&dir);
    }
}
