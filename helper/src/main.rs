//! filetree-helper: the helper process of filetree.nvim's own tree (`native.fs.helper`).
//!
//! One child process per Neovim, started by the editor, talking msgpack-RPC over stdin/stdout. It
//! lists the files below a folder (with the ignore rules `rg` uses), adds up the size of a folder,
//! watches a folder tree, and can read the git status of a repository (measured, not used by the
//! tree: `git` is as fast).
//!
//! What it never does: open a socket, start a process, write to the file system, read the content of
//! a file other than ignore files and what git keeps below `.git`. It ends when its stdin closes.
//!
//! Protocol (version 3). The editor sends notifications `[2, method, params]`; every one carries a
//! generation number as its first parameter, and every answer carries the generation of its request:
//!
//! - `walk [gen, root, options?]` -> `files [gen, paths]`*, then `done [gen, {ok, files, ms}]`;
//!   `options` (protocol 3, every key optional): `hidden` (bool, default true), `ignore`
//!   (`"gitignore"` default, `"names"` with `names` = folder names not entered, `"none"`),
//!   `no_ignore` (bool: `ignore = "none"` unless `ignore` is given), `follow` (bool), `exclude`
//!   (globs as `fd --exclude`), `max_depth` (1 = the files of the root). `.git` is never entered.
//!   An option that does not parse is answered with `error [gen, text]` and no `done`
//! - `cancel [gen]`: the walk of that generation sends nothing more
//! - `size [gen, dir]` -> `size [gen, {files, bytes, ms}]`
//! - `watch [gen, root]` -> `watching [gen, root]`, then `changed [gen, dirs]` after a short quiet,
//!   until `unwatch [gen]`; `error [gen, text]` when it cannot watch (any more). On Linux the folders
//!   are watched one by one and ignored ones are left out (`watch.rs`), so:
//! - `follow [gen, dir]`: the watch of that generation watches `dir` too, whatever the ignore rules
//!   say (the editor shows it); answered with `changed [gen, [dir]]` when that watch is new
//! - `status [gen, root]` -> `status [gen, {full, set, gone, entries, ms}]` (a delta after the first)
//! - request `ping` -> `{name, version, protocol, pid}`
//!
//! An answer is a notification the editor runs itself: `nvim_exec_lua(SINK, [kind, gen, payload])`,
//! where SINK is `return require('<module>').on(...)`. The module is `filetree.native.fs.helper`, or
//! the one named by `FILETREE_HELPER_SINK` (letters, digits, `_` and `.` only; lib.nvim names its
//! own client, `lib.nvim.fs.helper`). A name with any other character is not used.
//!
//! `filetree-helper walk <root> [--print]`, `size <dir>` and `status <root> [--print]` run one piece
//! of work without the protocol and print what it cost.

mod paths;
mod status;
mod walk;
mod watch;

use std::collections::HashMap;
use std::io::{self, BufReader, BufWriter, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Instant;

use rmpv::Value;

/// The module whose `on` gets every answer when `FILETREE_HELPER_SINK` names none.
const SINK_MODULE: &str = "filetree.native.fs.helper";

/// Bumped when a method or an answer changes shape.
const PROTOCOL: u64 = 3;

/// The Lua the editor runs for every answer; its arguments are `kind, generation, payload`.
fn sink() -> &'static str {
    static SINK: OnceLock<String> = OnceLock::new();
    SINK.get_or_init(|| sink_for(std::env::var("FILETREE_HELPER_SINK").ok().as_deref()))
}

/// The sink for a module name; a name that could be more than a module path is not used.
fn sink_for(name: Option<&str>) -> String {
    let module = name
        .filter(|name| {
            !name.is_empty()
                && name.len() <= 128
                && name
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
        })
        .unwrap_or(SINK_MODULE);
    format!("return require('{module}').on(...)")
}

/// The options of a `walk` (protocol 3); nil or a missing key keeps what the listing did before.
fn walk_options(value: Option<&Value>) -> Result<walk::Options, String> {
    let mut options = walk::Options::default();
    let Some(value) = value else {
        return Ok(options);
    };
    if value.is_nil() {
        return Ok(options);
    }
    let Some(pairs) = value.as_map() else {
        return Err("walk options must be a map".into());
    };
    let mut ignore: Option<String> = None;
    let mut names: Vec<String> = Vec::new();
    let mut no_ignore = false;
    for (key, value) in pairs {
        let flag = || {
            value
                .as_bool()
                .ok_or_else(|| format!("walk option {key} must be a boolean"))
        };
        let strings = || -> Result<Vec<String>, String> {
            value
                .as_array()
                .ok_or_else(|| format!("walk option {key} must be a list of strings"))?
                .iter()
                .map(|item| {
                    item.as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| format!("walk option {key} must be a list of strings"))
                })
                .collect()
        };
        match key.as_str().unwrap_or("") {
            "hidden" => options.hidden = flag()?,
            "follow" => options.follow = flag()?,
            "no_ignore" => no_ignore = flag()?,
            "exclude" => options.exclude = strings()?,
            "names" => names = strings()?,
            "ignore" => {
                ignore = Some(
                    value
                        .as_str()
                        .ok_or("walk option ignore must be a string")?
                        .to_owned(),
                )
            }
            "max_depth" => {
                options.max_depth = match value.as_u64() {
                    Some(depth) => Some(depth as usize),
                    None if value.is_nil() => None,
                    None => return Err("walk option max_depth must be a whole number".into()),
                }
            }
            other => return Err(format!("unknown walk option {other:?}")),
        }
    }
    options.ignore = match ignore.as_deref() {
        None if no_ignore => walk::Ignore::Nothing,
        None | Some("gitignore") => walk::Ignore::Gitignore,
        Some("names") => walk::Ignore::Names(names),
        Some("none") => walk::Ignore::Nothing,
        Some(other) => return Err(format!("walk option ignore: unknown {other:?}")),
    };
    Ok(options)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("serve") => serve(),
        Some("walk") => cli_walk(&args[1..]),
        Some("size") => cli_size(&args[1..]),
        Some("status") => cli_status(&args[1..]),
        Some("--version") => {
            println!(
                "filetree-helper {} (protocol {PROTOCOL})",
                env!("CARGO_PKG_VERSION")
            );
            ExitCode::SUCCESS
        }
        Some(other) => {
            eprintln!(
                "filetree-helper: unknown command '{other}' (serve, walk <root>, size <dir>, status <root>)"
            );
            ExitCode::from(2)
        }
    }
}

fn cli_walk(args: &[String]) -> ExitCode {
    let Some(root) = args.first() else {
        eprintln!("filetree-helper walk: missing <root>");
        return ExitCode::from(2);
    };
    let print = args.iter().any(|arg| arg == "--print");
    let started = Instant::now();
    let cancel = AtomicBool::new(false);
    let out = Mutex::new(BufWriter::new(io::stdout()));
    let summary = walk::run(root, &cancel, &|batch| {
        if print {
            let mut out = out.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            for path in batch {
                let _ = writeln!(out, "{path}");
            }
        }
    });
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    eprintln!("files={} ms={ms:.1}", summary.files);
    ExitCode::SUCCESS
}

fn cli_size(args: &[String]) -> ExitCode {
    let Some(dir) = args.first() else {
        eprintln!("filetree-helper size: missing <dir>");
        return ExitCode::from(2);
    };
    let started = Instant::now();
    let (files, bytes) = walk::size(dir);
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    println!("{bytes}");
    eprintln!("files={files} bytes={bytes} ms={ms:.1}");
    ExitCode::SUCCESS
}

fn cli_status(args: &[String]) -> ExitCode {
    let Some(root) = args.first() else {
        eprintln!("filetree-helper status: missing <root>");
        return ExitCode::from(2);
    };
    let started = Instant::now();
    match status::read(root) {
        Ok(map) => {
            let ms = started.elapsed().as_secs_f64() * 1000.0;
            if args.iter().any(|arg| arg == "--print") {
                for (path, code) in &map {
                    println!("{code} {path}");
                }
            }
            eprintln!("entries={} ms={ms:.1}", map.len());
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("filetree-helper status: {err}");
            ExitCode::FAILURE
        }
    }
}

/// An answer: the notification that makes the editor call the sink.
fn event(kind: &str, generation: u64, payload: Value) -> Value {
    Value::Array(vec![
        Value::from(2),
        Value::from("nvim_exec_lua"),
        Value::Array(vec![
            Value::from(sink()),
            Value::Array(vec![Value::from(kind), Value::from(generation), payload]),
        ]),
    ])
}

fn map(pairs: Vec<(&str, Value)>) -> Value {
    Value::Map(
        pairs
            .into_iter()
            .map(|(key, value)| (Value::from(key), value))
            .collect(),
    )
}

struct Server {
    out: Sender<Value>,
    walks: HashMap<u64, Arc<AtomicBool>>,
    watches: HashMap<u64, watch::Watch>,
    /// The last status sent, per repository root: what the next answer is a delta against.
    seen: Arc<Mutex<status::Seen>>,
}

fn serve() -> ExitCode {
    let (out, messages) = mpsc::channel::<Value>();
    // one thread owns stdout: a message is never interleaved with another one
    let writer = thread::spawn(move || {
        let mut stdout = BufWriter::with_capacity(1 << 16, io::stdout().lock());
        for message in messages {
            if rmpv::encode::write_value(&mut stdout, &message).is_err() || stdout.flush().is_err()
            {
                // the editor is gone
                std::process::exit(0);
            }
        }
    });

    let mut server = Server {
        out,
        walks: HashMap::new(),
        watches: HashMap::new(),
        seen: Arc::default(),
    };
    let mut input = BufReader::new(io::stdin().lock());
    // ends with the editor: a closed stdin (or anything that is not msgpack) is the end
    while let Ok(message) = rmpv::decode::read_value(&mut input) {
        server.dispatch(&message);
    }
    drop(server);
    let _ = writer.join();
    ExitCode::SUCCESS
}

impl Server {
    fn dispatch(&mut self, message: &Value) {
        let Some(parts) = message.as_array() else {
            return;
        };
        match parts.first().and_then(Value::as_u64) {
            // request: [0, id, method, params]
            Some(0) if parts.len() == 4 => {
                let (error, result) = match parts[2].as_str() {
                    Some("ping") => (
                        Value::Nil,
                        map(vec![
                            ("name", Value::from("filetree-helper")),
                            ("version", Value::from(env!("CARGO_PKG_VERSION"))),
                            ("protocol", Value::from(PROTOCOL)),
                            ("pid", Value::from(std::process::id())),
                        ]),
                    ),
                    other => (
                        Value::from(format!("unknown request {other:?}")),
                        Value::Nil,
                    ),
                };
                let _ = self.out.send(Value::Array(vec![
                    Value::from(1),
                    parts[1].clone(),
                    error,
                    result,
                ]));
            }
            // notification: [2, method, params]
            Some(2) if parts.len() == 3 => {
                let params = parts[2].as_array().map(Vec::as_slice).unwrap_or(&[]);
                let Some(generation) = params.first().and_then(Value::as_u64) else {
                    return;
                };
                self.notify(parts[1].as_str().unwrap_or(""), generation, &params[1..]);
            }
            _ => {}
        }
    }

    fn notify(&mut self, method: &str, generation: u64, params: &[Value]) {
        let root = params.first().and_then(Value::as_str).map(str::to_owned);
        match (method, root) {
            ("size", Some(dir)) => {
                let out = self.out.clone();
                thread::spawn(move || {
                    let started = Instant::now();
                    let (files, bytes) = walk::size(&dir);
                    let answer = map(vec![
                        ("files", Value::from(files)),
                        ("bytes", Value::from(bytes)),
                        ("ms", Value::from(started.elapsed().as_secs_f64() * 1000.0)),
                    ]);
                    let _ = out.send(event("size", generation, answer));
                });
            }
            ("walk", Some(root)) => {
                let options = match walk_options(params.get(1)) {
                    Ok(options) => options,
                    Err(err) => {
                        let _ = self.out.send(event("error", generation, Value::from(err)));
                        return;
                    }
                };
                let cancel = Arc::new(AtomicBool::new(false));
                self.walks.retain(|_, flag| Arc::strong_count(flag) > 1);
                self.walks.insert(generation, Arc::clone(&cancel));
                let out = self.out.clone();
                thread::spawn(move || {
                    let started = Instant::now();
                    let listed = walk::run_with(&root, &options, &cancel, &|batch| {
                        if cancel.load(Ordering::Relaxed) {
                            return;
                        }
                        let paths = Value::Array(batch.into_iter().map(Value::from).collect());
                        let _ = out.send(event("files", generation, paths));
                    });
                    if cancel.load(Ordering::Relaxed) {
                        return;
                    }
                    let summary = match listed {
                        Ok(summary) => summary,
                        Err(err) => {
                            let _ = out.send(event("error", generation, Value::from(err)));
                            return;
                        }
                    };
                    let done = map(vec![
                        ("ok", Value::from(summary.ok)),
                        ("files", Value::from(summary.files)),
                        ("ms", Value::from(started.elapsed().as_secs_f64() * 1000.0)),
                    ]);
                    let _ = out.send(event("done", generation, done));
                });
            }
            ("cancel", _) => {
                if let Some(flag) = self.walks.remove(&generation) {
                    flag.store(true, Ordering::Relaxed);
                }
            }
            ("watch", Some(root)) => {
                let out = self.out.clone();
                let watched = root.clone();
                let watch = watch::start(&root, move |report| {
                    let (kind, payload) = match report {
                        watch::Report::Watching => ("watching", Value::from(watched.as_str())),
                        watch::Report::Changed(dirs) => (
                            "changed",
                            Value::Array(dirs.into_iter().map(Value::from).collect()),
                        ),
                        watch::Report::Failed(why) => ("error", Value::from(why)),
                    };
                    let _ = out.send(event(kind, generation, payload));
                });
                self.watches.insert(generation, watch);
            }
            ("follow", Some(dir)) => {
                if let Some(watch) = self.watches.get(&generation) {
                    watch.follow(&dir);
                }
            }
            ("unwatch", _) => {
                self.watches.remove(&generation);
            }
            ("status", Some(root)) => {
                let out = self.out.clone();
                let seen = Arc::clone(&self.seen);
                thread::spawn(move || {
                    let started = Instant::now();
                    let now = match status::read(&root) {
                        Ok(now) => now,
                        Err(err) => {
                            let _ = out.send(event("error", generation, Value::from(err)));
                            return;
                        }
                    };
                    let entries = now.len();
                    let answer = seen
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .advance(&root, generation, now);
                    // a newer generation was answered first: this one would be dropped anyway
                    let Some((full, delta)) = answer else { return };
                    let payload = map(vec![
                        ("full", Value::from(full)),
                        (
                            "set",
                            Value::Map(
                                delta
                                    .set
                                    .into_iter()
                                    .map(|(path, code)| (Value::from(path), Value::from(code)))
                                    .collect(),
                            ),
                        ),
                        (
                            "gone",
                            Value::Array(delta.gone.into_iter().map(Value::from).collect()),
                        ),
                        ("entries", Value::from(entries)),
                        ("ms", Value::from(started.elapsed().as_secs_f64() * 1000.0)),
                    ]);
                    let _ = out.send(event("status", generation, payload));
                });
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts(pairs: Vec<(&str, Value)>) -> Result<walk::Options, String> {
        walk_options(Some(&map(pairs)))
    }

    #[test]
    fn no_options_keep_the_listing_of_protocol_2() {
        assert_eq!(walk_options(None).unwrap(), walk::Options::default());
        assert_eq!(
            walk_options(Some(&Value::Nil)).unwrap(),
            walk::Options::default()
        );
        assert_eq!(opts(vec![]).unwrap(), walk::Options::default());
    }

    #[test]
    fn every_option_is_read() {
        let got = opts(vec![
            ("hidden", Value::from(false)),
            ("follow", Value::from(true)),
            ("exclude", Value::Array(vec![Value::from("*.log")])),
            ("max_depth", Value::from(3)),
            ("ignore", Value::from("names")),
            ("names", Value::Array(vec![Value::from("node_modules")])),
        ])
        .unwrap();
        assert!(!got.hidden && got.follow);
        assert_eq!(got.exclude, vec!["*.log".to_string()]);
        assert_eq!(got.max_depth, Some(3));
        assert_eq!(got.ignore, walk::Ignore::Names(vec!["node_modules".into()]));
    }

    #[test]
    fn no_ignore_means_none_unless_ignore_is_given() {
        let only = opts(vec![("no_ignore", Value::from(true))]).unwrap();
        assert_eq!(only.ignore, walk::Ignore::Nothing);
        let both = opts(vec![
            ("no_ignore", Value::from(true)),
            ("ignore", Value::from("gitignore")),
        ])
        .unwrap();
        assert_eq!(both.ignore, walk::Ignore::Gitignore);
    }

    #[test]
    fn a_wrong_option_is_an_error() {
        assert!(opts(vec![("hidden", Value::from("yes"))]).is_err());
        assert!(opts(vec![("ignore", Value::from("all"))]).is_err());
        assert!(opts(vec![("depth", Value::from(1))]).is_err());
        assert!(walk_options(Some(&Value::from(1))).is_err());
    }

    #[test]
    fn the_sink_names_a_module_only() {
        assert_eq!(
            sink_for(None),
            "return require('filetree.native.fs.helper').on(...)"
        );
        assert_eq!(
            sink_for(Some("lib.nvim.fs.helper")),
            "return require('lib.nvim.fs.helper').on(...)"
        );
        assert_eq!(sink_for(Some("x');os.exit()--")), sink_for(None));
        assert_eq!(sink_for(Some("")), sink_for(None));
    }
}
