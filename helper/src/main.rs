//! filetree-helper: prototype of the helper process of filetree.nvim's own tree (stage E3h).
//!
//! One child process per Neovim, started by the editor, talking msgpack-RPC over stdin/stdout. It
//! lists the files below a folder (with the ignore rules `rg` uses), watches a folder tree and reads
//! the git status of a repository, reporting only what changed since it was last asked.
//!
//! What it never does: open a socket, start a process, write to the file system, read the content of
//! a file other than ignore files and what git keeps below `.git`. It ends when its stdin closes.
//!
//! Protocol. The editor sends notifications `[2, method, params]`; every one carries a generation
//! number as its first parameter, and every answer carries the generation of its request:
//!
//! - `walk [gen, root, {sizes?: bool}]` -> `files [gen, paths]`*, then `done [gen, {ok, files, bytes, ms}]`
//! - `cancel [gen]`: the walk of that generation sends nothing more
//! - `watch [gen, root]` -> `changed [gen, dirs]` after a short quiet, until `unwatch [gen]`
//! - `status [gen, root]` -> `status [gen, {full, set, gone, ms}]` (a delta after the first answer)
//! - request `ping` -> `{name, version, pid}`
//!
//! An answer is a notification the editor runs itself: `nvim_exec_lua(SINK, [kind, gen, payload])`.
//!
//! `filetree-helper walk <root>` and `filetree-helper status <root>` run one piece of work without
//! the protocol and print what it cost (for measuring without the transport).

mod paths;
mod status;
mod walk;
mod watch;

use std::collections::HashMap;
use std::io::{self, BufReader, BufWriter, Write};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

use rmpv::Value;

/// The Lua the editor runs for every answer; its arguments are `kind, generation, payload`.
const SINK: &str = "return require('filetree_helper').on(...)";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        None | Some("serve") => serve(),
        Some("walk") => cli_walk(&args[1..]),
        Some("status") => cli_status(&args[1..]),
        Some("--version") => {
            println!("filetree-helper {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Some(other) => {
            eprintln!("filetree-helper: unknown command '{other}' (serve, walk <root> [--sizes], status <root>)");
            ExitCode::from(2)
        }
    }
}

fn cli_walk(args: &[String]) -> ExitCode {
    let Some(root) = args.first() else {
        eprintln!("filetree-helper walk: missing <root>");
        return ExitCode::from(2);
    };
    let sizes = args.iter().any(|arg| arg == "--sizes");
    let print = args.iter().any(|arg| arg == "--print");
    let started = Instant::now();
    let cancel = AtomicBool::new(false);
    let out = Mutex::new(BufWriter::new(io::stdout()));
    let summary = walk::run(root, sizes, &cancel, &|batch| {
        if print {
            let mut out = out.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            for path in batch {
                let _ = writeln!(out, "{path}");
            }
        }
    });
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    eprintln!("files={} bytes={} ms={ms:.1}", summary.files, summary.bytes);
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
            Value::from(SINK),
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
            ("walk", Some(root)) => {
                let sizes = params
                    .get(1)
                    .and_then(Value::as_map)
                    .and_then(|opts| opts.iter().find(|(key, _)| key.as_str() == Some("sizes")))
                    .and_then(|(_, value)| value.as_bool())
                    .unwrap_or(false);
                let cancel = Arc::new(AtomicBool::new(false));
                self.walks.retain(|_, flag| Arc::strong_count(flag) > 1);
                self.walks.insert(generation, Arc::clone(&cancel));
                let out = self.out.clone();
                thread::spawn(move || {
                    let started = Instant::now();
                    let summary = walk::run(&root, sizes, &cancel, &|batch| {
                        if cancel.load(Ordering::Relaxed) {
                            return;
                        }
                        let paths = Value::Array(batch.into_iter().map(Value::from).collect());
                        let _ = out.send(event("files", generation, paths));
                    });
                    if cancel.load(Ordering::Relaxed) {
                        return;
                    }
                    let done = map(vec![
                        ("ok", Value::from(summary.ok)),
                        ("files", Value::from(summary.files)),
                        ("bytes", Value::from(summary.bytes)),
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
                let started = watch::start(&root, move |dirs| {
                    let dirs = Value::Array(dirs.into_iter().map(Value::from).collect());
                    let _ = out.send(event("changed", generation, dirs));
                });
                match started {
                    Ok(watch) => {
                        self.watches.insert(generation, watch);
                        let _ = self
                            .out
                            .send(event("watching", generation, Value::from(root)));
                    }
                    Err(err) => {
                        let _ =
                            self.out
                                .send(event("error", generation, Value::from(err.to_string())));
                    }
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
