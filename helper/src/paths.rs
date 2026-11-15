//! One spelling for a path, the one `filetree.native.fs.list.norm` uses: `/`-separated, drive letter
//! upper case.

use std::path::Path;

/// Normalize a path the way the Lua side does, so that it can be used as a node id unchanged.
///
/// A name that is not valid UTF-8 is spelled with replacement characters (a prototype's shortcut: the
/// editor could not open such a path from this string).
pub fn norm(path: &Path) -> String {
    let mut text = path.to_string_lossy().replace('\\', "/");
    let bytes = text.as_bytes();
    if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_lowercase() {
        let drive = bytes[0].to_ascii_uppercase() as char;
        text.replace_range(0..1, &drive.to_string());
    }
    text
}

/// The folder a normalized path lies in, or `None` at the top.
pub fn parent(path: &str) -> Option<&str> {
    let cut = path.rfind('/')?;
    if cut == 0 {
        return Some("/");
    }
    let head = &path[..cut];
    if head.len() == 2 && head.as_bytes()[1] == b':' {
        // `C:/x` lies in `C:/`
        return Some(&path[..=cut]);
    }
    Some(head)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn norm_matches_the_lua_spelling() {
        assert_eq!(norm(Path::new("e:\\repos\\x\\a.lua")), "E:/repos/x/a.lua");
        assert_eq!(
            norm(Path::new("E:/repos/x\\sub/a.lua")),
            "E:/repos/x/sub/a.lua"
        );
        assert_eq!(norm(Path::new("/home/u/x")), "/home/u/x");
    }

    #[test]
    fn parent_of_a_path() {
        assert_eq!(parent("E:/repos/x/a.lua"), Some("E:/repos/x"));
        assert_eq!(parent("E:/a.lua"), Some("E:/"));
        assert_eq!(parent("/a"), Some("/"));
        assert_eq!(parent("/home/u"), Some("/home"));
        assert_eq!(parent("a"), None);
    }
}
