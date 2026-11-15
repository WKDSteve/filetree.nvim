//! Every file below a folder, in batches, with the ignore rules of `rg` (the `ignore` crate).
//!
//! Lists what `filetree.native.fs.deep` lists through `fd`: files, hidden ones too, never `.git`,
//! nothing an ignore file names; a link to a file (or a broken link) is a file, a link to a folder is
//! neither listed nor followed.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use ignore::{DirEntry, Error, ParallelVisitor, ParallelVisitorBuilder, WalkBuilder, WalkState};

use crate::paths;

/// How many paths go into one message.
const BATCH: usize = 1000;

pub struct Summary {
    /// False when the walk was cancelled.
    pub ok: bool,
    pub files: u64,
    /// Sum of the file sizes; 0 unless sizes were asked for.
    pub bytes: u64,
}

struct Shared<'a> {
    cancel: &'a AtomicBool,
    sink: &'a (dyn Fn(Vec<String>) + Sync),
    sizes: bool,
    files: AtomicU64,
    bytes: AtomicU64,
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
        if self.shared.sizes {
            if let Ok(meta) = entry.metadata() {
                self.shared.bytes.fetch_add(meta.len(), Ordering::Relaxed);
            }
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

/// List every file below `root`; `sink` gets the batches, from several threads.
pub fn run(
    root: &str,
    sizes: bool,
    cancel: &AtomicBool,
    sink: &(dyn Fn(Vec<String>) + Sync),
) -> Summary {
    let shared = Shared {
        cancel,
        sink,
        sizes,
        files: AtomicU64::new(0),
        bytes: AtomicU64::new(0),
    };
    let walker = WalkBuilder::new(root)
        .hidden(false)
        .follow_links(false)
        .filter_entry(|entry| entry.file_name() != ".git")
        .build_parallel();
    walker.visit(&mut Builder { shared: &shared });
    Summary {
        ok: !cancel.load(Ordering::Relaxed),
        files: shared.files.load(Ordering::Relaxed),
        bytes: shared.bytes.load(Ordering::Relaxed),
    }
}
