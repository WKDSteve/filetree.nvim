//! The git status of a repository, read in this process (gitoxide), and the difference between two
//! of them.
//!
//! A status is a map from the path (normalized, absolute) to a two-letter code in the manner of
//! `git status --porcelain`: the first letter is the index against `HEAD`, the second the working
//! tree against the index, `??` is untracked.

use std::collections::BTreeMap;

use gix::bstr::ByteSlice;
use gix::status::index_worktree::iter::Summary;
use gix::status::{Item, UntrackedFiles};

use crate::paths;

pub struct Delta {
    /// Paths whose code is new or changed.
    pub set: Vec<(String, String)>,
    /// Paths that have no code any more.
    pub gone: Vec<String>,
}

fn put(
    map: &mut BTreeMap<String, String>,
    path: String,
    index: Option<char>,
    worktree: Option<char>,
) {
    let code = map.entry(path).or_insert_with(|| "  ".to_owned());
    let mut letters: Vec<char> = code.chars().collect();
    if let Some(letter) = index {
        letters[0] = letter;
    }
    if let Some(letter) = worktree {
        letters[1] = letter;
    }
    *code = letters.into_iter().collect();
}

/// Read the status of the repository `root` lies in.
pub fn read(root: &str) -> Result<BTreeMap<String, String>, String> {
    let repo = gix::discover(root).map_err(|err| err.to_string())?;
    let workdir = repo
        .workdir()
        .ok_or("a bare repository has no status")?
        .to_owned();
    let items = repo
        .status(gix::progress::Discard)
        .map_err(|err| err.to_string())?
        .untracked_files(UntrackedFiles::Files)
        .into_iter(None)
        .map_err(|err| err.to_string())?;

    let mut map = BTreeMap::new();
    for item in items {
        let item = item.map_err(|err| err.to_string())?;
        let path = paths::norm(&workdir.join(item.location().to_path_lossy()));
        match &item {
            Item::IndexWorktree(change) => match change.summary() {
                Some(Summary::Added) => put(&mut map, path, Some('?'), Some('?')),
                Some(Summary::Removed) => put(&mut map, path, None, Some('D')),
                Some(Summary::Modified) => put(&mut map, path, None, Some('M')),
                Some(Summary::TypeChange) => put(&mut map, path, None, Some('T')),
                Some(Summary::Renamed) => put(&mut map, path, None, Some('R')),
                Some(Summary::Copied) => put(&mut map, path, None, Some('C')),
                Some(Summary::IntentToAdd) => put(&mut map, path, None, Some('A')),
                Some(Summary::Conflict) => put(&mut map, path, Some('U'), Some('U')),
                None => {}
            },
            Item::TreeIndex(change) => {
                use gix::diff::index::ChangeRef;
                let letter = match change {
                    ChangeRef::Addition { .. } => 'A',
                    ChangeRef::Deletion { .. } => 'D',
                    ChangeRef::Modification { .. } => 'M',
                    ChangeRef::Rewrite { .. } => 'R',
                };
                put(&mut map, path, Some(letter), None);
            }
        }
    }
    Ok(map)
}

/// What changed from `before` to `now`; without a `before` everything is new.
pub fn delta(before: Option<&BTreeMap<String, String>>, now: &BTreeMap<String, String>) -> Delta {
    let empty = BTreeMap::new();
    let before = before.unwrap_or(&empty);
    let set = now
        .iter()
        .filter(|(path, code)| before.get(*path) != Some(*code))
        .map(|(path, code)| (path.clone(), code.clone()))
        .collect();
    let gone = before
        .keys()
        .filter(|path| !now.contains_key(*path))
        .cloned()
        .collect();
    Delta { set, gone }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(path, code)| ((*path).to_owned(), (*code).to_owned()))
            .collect()
    }

    #[test]
    fn the_first_delta_is_everything() {
        let now = status(&[("/r/a", " M"), ("/r/b", "??")]);
        let delta = delta(None, &now);
        assert_eq!(delta.set.len(), 2);
        assert!(delta.gone.is_empty());
    }

    #[test]
    fn a_delta_names_only_what_changed() {
        let before = status(&[("/r/a", " M"), ("/r/b", "??"), ("/r/c", "A ")]);
        let now = status(&[("/r/a", " M"), ("/r/b", "A "), ("/r/d", "??")]);
        let delta = delta(Some(&before), &now);
        assert_eq!(
            delta.set,
            vec![
                ("/r/b".to_owned(), "A ".to_owned()),
                ("/r/d".to_owned(), "??".to_owned())
            ]
        );
        assert_eq!(delta.gone, vec!["/r/c".to_owned()]);
    }

    #[test]
    fn index_and_worktree_letters_share_a_code() {
        let mut map = BTreeMap::new();
        put(&mut map, "/r/a".to_owned(), Some('M'), None);
        put(&mut map, "/r/a".to_owned(), None, Some('D'));
        assert_eq!(map["/r/a"], "MD");
    }
}
