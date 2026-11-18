//! Every file below a folder, in batches, with the ignore rules of `rg` (the `ignore` crate); and the
//! size of a folder with everything in it.
//!
//! `run` lists what `filetree.native.fs.deep` lists through `fd`: files, hidden ones too, never
//! `.git`, nothing an ignore file names; a link to a file (or a broken link) is a file, a link to a
//! folder is neither listed nor followed.
//!
//! `run_with` takes `Options` (protocol 3): the switches of `fd` (`hidden`, `follow`, `exclude`,
//! `max_depth`) and which ignore rules count (`.gitignore` and the like, a list of folder names, or
//! none). `.git` is never entered, whatever the options say.
//!
//! `size` counts what `du` counts: every file, ignored ones and `.git` too; links are not followed.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use ignore::overrides::OverrideBuilder;
use ignore::{DirEntry, Error, ParallelVisitor, ParallelVisitorBuilder, WalkBuilder, WalkState};

use crate::paths;

/// How many paths go into one message.
const BATCH: usize = 1000;

/// Which rules leave entries out of a listing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ignore {
    /// `.gitignore`, `.ignore`, `.git/info/exclude` and the global excludes, as `fd` and `rg` read them.
    Gitignore,
    /// No ignore file: the folders with one of these names are not entered.
    Names(Vec<String>),
    /// No ignore file, no name.
    Nothing,
}

/// How a listing walks (protocol 3). `Options::default()` is what the listing did before options.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Options {
    /// Hidden entries (a dot name) are listed and walked into.
    pub hidden: bool,
    pub ignore: Ignore,
    /// A link to a folder is followed (a loop is reported by the walk and left out).
    pub follow: bool,
    /// Globs as `fd --exclude` takes them (gitignore syntax): a match is neither listed nor walked into.
    pub exclude: Vec<String>,
    /// 1: the files directly in the root, as `fd --max-depth`.
    pub max_depth: Option<usize>,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            hidden: true,
            ignore: Ignore::Gitignore,
            follow: false,
            exclude: Vec::new(),
            max_depth: None,
        }
    }
}

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
        // without `follow` a link to a folder is neither listed nor walked into
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

/// The walk of a listing with `options`; an `exclude` glob that does not parse is the error.
pub fn builder(root: &str, options: &Options) -> Result<WalkBuilder, String> {
    let mut builder = WalkBuilder::new(root);
    if options.ignore != Ignore::Gitignore {
        builder.standard_filters(false);
    }
    // after `standard_filters`, which sets `hidden` too
    builder
        .hidden(!options.hidden)
        .follow_links(options.follow)
        .max_depth(options.max_depth);
    if !options.exclude.is_empty() {
        let mut globs = OverrideBuilder::new(root);
        for glob in &options.exclude {
            globs
                .add(&format!("!{glob}"))
                .map_err(|err| format!("exclude {glob:?}: {err}"))?;
        }
        builder.overrides(globs.build().map_err(|err| err.to_string())?);
    }
    if let Ignore::Names(names) = &options.ignore {
        let names: Vec<std::ffi::OsString> = names.iter().map(Into::into).collect();
        builder.filter_entry(move |entry| {
            kept(entry)
                && !(entry.file_type().is_some_and(|kind| kind.is_dir())
                    && names
                        .iter()
                        .any(|name| entry.file_name() == name.as_os_str()))
        });
    } else {
        builder.filter_entry(kept);
    }
    Ok(builder)
}

/// List every file below `root`; `sink` gets the batches, from several threads.
pub fn run(root: &str, cancel: &AtomicBool, sink: &(dyn Fn(Vec<String>) + Sync)) -> Summary {
    run_with(root, &Options::default(), cancel, sink).unwrap_or(Summary {
        ok: false,
        files: 0,
    })
}

/// `run` with options; Err when an `exclude` glob does not parse (nothing was listed then).
pub fn run_with(
    root: &str,
    options: &Options,
    cancel: &AtomicBool,
    sink: &(dyn Fn(Vec<String>) + Sync),
) -> Result<Summary, String> {
    let walk = builder(root, options)?;
    let shared = Shared {
        cancel,
        sink,
        files: AtomicU64::new(0),
    };
    walk.build_parallel()
        .visit(&mut Builder { shared: &shared });
    Ok(Summary {
        ok: !cancel.load(Ordering::Relaxed),
        files: shared.files.load(Ordering::Relaxed),
    })
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

    fn listed(dir: &std::path::Path, options: &Options) -> Vec<String> {
        let found = Mutex::new(Vec::new());
        let cancel = AtomicBool::new(false);
        let summary = run_with(dir.to_str().unwrap(), options, &cancel, &|batch| {
            found.lock().unwrap().extend(batch)
        })
        .unwrap();
        assert!(summary.ok);
        let base = paths::norm(dir);
        let mut found: Vec<String> = found
            .into_inner()
            .unwrap()
            .into_iter()
            .map(|path| path[base.len() + 1..].to_string())
            .collect();
        found.sort();
        assert_eq!(summary.files as usize, found.len());
        found
    }

    /// The fixture plus a hidden folder, a `node_modules` and a log file one level down.
    fn rich(name: &str) -> std::path::PathBuf {
        let dir = fixture(name);
        fs::create_dir_all(dir.join(".hidden")).unwrap();
        fs::create_dir_all(dir.join("node_modules/pkg")).unwrap();
        fs::write(dir.join(".hidden/h.txt"), "h").unwrap();
        fs::write(dir.join("node_modules/pkg/n.js"), "n").unwrap();
        fs::write(dir.join("sub/s.log"), "s").unwrap();
        dir
    }

    #[test]
    fn the_default_options_list_what_the_listing_listed_before() {
        let dir = rich("default");
        let found = listed(&dir, &Options::default());
        let cancel = AtomicBool::new(false);
        let before = Mutex::new(Vec::new());
        run(dir.to_str().unwrap(), &cancel, &|batch| {
            before.lock().unwrap().extend(batch)
        });
        assert_eq!(found.len(), before.into_inner().unwrap().len());
        assert!(found.contains(&".hidden/h.txt".to_string()));
        assert!(!found.iter().any(|path| path.starts_with("ignored/")));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn hidden_false_leaves_out_dot_entries() {
        let dir = rich("hidden");
        let options = Options {
            hidden: false,
            ..Options::default()
        };
        let found = listed(&dir, &options);
        assert!(!found
            .iter()
            .any(|path| path.starts_with('.') || path.contains("/.")));
        assert!(found.contains(&"a.txt".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn ignore_nothing_lists_ignored_files_but_never_git() {
        let dir = rich("nothing");
        let options = Options {
            ignore: Ignore::Nothing,
            ..Options::default()
        };
        let found = listed(&dir, &options);
        assert!(found.contains(&"ignored/c.txt".to_string()));
        assert!(found.contains(&"node_modules/pkg/n.js".to_string()));
        assert!(!found.iter().any(|path| path.starts_with(".git/")));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn ignore_names_skips_the_named_folders_only() {
        let dir = rich("names");
        let options = Options {
            ignore: Ignore::Names(vec!["node_modules".into()]),
            ..Options::default()
        };
        let found = listed(&dir, &options);
        assert!(found.contains(&"ignored/c.txt".to_string()));
        assert!(!found.iter().any(|path| path.starts_with("node_modules/")));
        assert!(!found.iter().any(|path| path.starts_with(".git/")));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn exclude_globs_leave_out_files_and_folders() {
        let dir = rich("exclude");
        let options = Options {
            ignore: Ignore::Nothing,
            exclude: vec!["*.log".into(), "node_modules".into()],
            ..Options::default()
        };
        let found = listed(&dir, &options);
        assert!(!found.iter().any(|path| path.ends_with(".log")));
        assert!(!found.iter().any(|path| path.starts_with("node_modules/")));
        assert!(found.contains(&"sub/deep/b.txt".to_string()));
        let bad = Options {
            exclude: vec!["a[".into()],
            ..Options::default()
        };
        let cancel = AtomicBool::new(false);
        assert!(run_with(dir.to_str().unwrap(), &bad, &cancel, &|_| {}).is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn max_depth_counts_like_fd() {
        let dir = rich("depth");
        let one = listed(
            &dir,
            &Options {
                max_depth: Some(1),
                ..Options::default()
            },
        );
        assert!(one.contains(&"a.txt".to_string()));
        assert!(!one.iter().any(|path| path.contains('/')));
        let two = listed(
            &dir,
            &Options {
                max_depth: Some(2),
                ..Options::default()
            },
        );
        assert!(two.contains(&"sub/s.log".to_string()));
        assert!(!two.contains(&"sub/deep/b.txt".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn follow_walks_into_a_linked_folder() {
        let dir = rich("follow");
        let outside = dir.with_extension("target");
        let _ = fs::remove_dir_all(&outside);
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("t.txt"), "t").unwrap();
        std::os::unix::fs::symlink(&outside, dir.join("link")).unwrap();
        let plain = listed(&dir, &Options::default());
        assert!(!plain.iter().any(|path| path.starts_with("link")));
        let followed = listed(
            &dir,
            &Options {
                follow: true,
                ..Options::default()
            },
        );
        assert!(followed.contains(&"link/t.txt".to_string()));
        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(&outside);
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
