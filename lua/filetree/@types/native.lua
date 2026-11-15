---@meta
---@module 'filetree.@types.native'
--- The contract of filetree.nvim's own tree: what a source, a decorator and an action are.
---
--- The three entry kinds are registered through `filetree.registry` and stored in
--- `lib.nvim.tree.registry`; the node shape is the one of `lib.nvim.tree`, plus `path` and `data`.

---A node of the tree. `path` is what file actions and path decorators go by: a node that has one is a
---file or a folder in every source (a buffer, a changed file, a spec file), whatever supplied it.
---@class Filetree.Node : Lib.Tree.Node
---@field path? string absolute path, `/`-separated, drive letter upper case
---@field data? table belongs to the source; the tree never touches it. `data.chain` (string[]): the ids of the folders a merged line `a/b/c` stands for, outermost first. Read when the node is opened: `data.bufnr` (integer, the buffer to show instead of a file), `data.lnum` and `data.col` (1-based line, 0-based column to go to)
--- `hl`, `open`, `lazy` and `expandable` are declared on `Lib.Tree.Node` (lib.nvim).

---What a source, a decorator or an action is called with.
---@class Filetree.Ctx
---@field root string the root directory of the view
---@field cwd string
---@field win integer the tree window
---@field view string the name of the view shown in it
---@field tree? table the tree view itself, handed to an action (not to a source): `ctx.tree:refresh()`, `ctx.tree:show(name)`
---@field mutable? boolean false: the source of the node does not let files be changed (actions)
---@field source? string the source the node in question came from
---@field alt_buf? integer the editor buffer the tree was opened from

---@class Filetree.Emit : Lib.Tree.Registry.Emit
---@field focus fun(id: any) put the cursor of the tree on a node of this source, opening what is above it; ignored while the user is in the tree window

---Supplies the nodes of one view.
---@class Filetree.Source : Lib.Tree.Registry.Source
---@field root fun(ctx: Filetree.Ctx): Filetree.Node
---@field children? fun(node: Filetree.Node, ctx: Filetree.Ctx, cb: fun(list?: Filetree.Node[], err?: string)) asked for the root when it carries no `children`, and for a node with `lazy = true`; answers like a node's own `children`
---@field subscribe? fun(ctx: Filetree.Ctx, emit: Filetree.Emit): fun()
---@field actions? Filetree.Action[]
---@field preview? fun(node: Filetree.Node, ctx: Filetree.Ctx): table|nil

---@class Filetree.Badge : Lib.Tree.Registry.Badge

---Badges on nodes. `get` runs while the tree draws: a table lookup, never I/O.
---What a decorator is handed when it subscribes, next to `emit`.
---@class Filetree.Decor.Ctx
---@field roots fun(): string[] the roots the trees show right now (one per tab that opened one), sorted; `User FiletreeRoots` (`data.roots`) fires when they change

---@class Filetree.Decorator : Lib.Tree.Registry.Decorator
---@field get fun(key: string, node?: Filetree.Node): Filetree.Badge|nil  `node` is given while a row is drawn, not when a changed key is re-read
---@field subscribe fun(emit: fun(keys?: string[]), ctx?: Filetree.Decor.Ctx): fun() tell which keys changed (nil: everything); `ctx.roots()` says what the trees show; returns unsubscribe
---@field all? fun(): table<string, Filetree.Badge> every key with a badge; needed for a folder to show what lies below it

---@class Filetree.ActionArg : Lib.Tree.Registry.ActionArg

---Something to do with the node under the cursor, or with the selection. One table feeds the keys, the
---cheatsheet, the context menu and `:Filetree`.
---@class Filetree.Action : Lib.Tree.Registry.Action
---@field ai? boolean false keeps the action out of the catalog a model picks from (`native.ai`); default true
---@field when? fun(node: Filetree.Node, ctx: Filetree.Ctx): boolean
---@field run fun(nodes: Filetree.Node[], ctx: Filetree.Ctx, args?: table<string, string>)

---A highlighted byte range of a rendered line.
---@class Filetree.Span
---@field col_start integer 0-based byte column
---@field col_end integer exclusive
---@field hl string highlight group
---@field id? any for a segment of a merged line: the node id that segment stands for

---One rendered line: what goes into the buffer, and where its parts are.
---@class Filetree.Line
---@field text string
---@field spans Filetree.Span[]
---@field name_start integer 0-based byte column where the name starts
---@field name_end integer exclusive

---Glyphs and widths the line renderer draws with. Every field is optional.
---@class Filetree.LineOpts
---@field indent? integer columns per level (default 2)
---@field guide? string drawn once per level instead of blanks, e.g. "│" (default: blanks)
---@field expander? { open: string, closed: string, loading: string, none: string } (default "▾", "▸", "…", " ")
---@field icon? fun(row: Lib.Tree.Row): string|nil, string|nil glyph and its highlight group
---@field trailing_slash? boolean append `/` to a folder: an expandable node, or one of kind "dir" (default false)
---@field hl? { guide?: string, expander?: string, name?: string, dir?: string } highlight groups

---What a source or a previewer is asked with for a preview: the context of the view (`Filetree.Ctx`,
---on the own tree) plus what the preview is.
---@class Filetree.Preview.Ctx : Filetree.Ctx
---@field mode "float"|"buffer" `features.preview.mode`: a float next to the tree, or the editor window
---@field trigger "toggle"|"cursor" `<Tab>` was pressed, or the cursor moved while a preview is shown
---@field width integer columns the preview may use (`max_width`)
---@field height integer lines the preview may use (`max_height`)

---What the preview shows in place of the file of a node. One of the three; `title` goes with each.
---@class Filetree.Preview.Result
---@field lines? string[] shown in the float, or in a scratch buffer in the editor window
---@field filetype? string of `lines`, for highlighting
---@field image? string path of an image: on `<Tab>` it goes to the image viewer as if the node were that image; while the cursor moves only its title is shown
---@field note? string one line that says why there is nothing to show ("ffmpeg not found")
---@field title? string the title of the preview (default: the label of the node)

---A preview for nodes another plugin can draw (a frame of a video, a waveform). Registered with
---`require("filetree").previewer` or `lib.nvim.tree.registry.previewer`.
---@class Filetree.Previewer
---@field name string unique among previewers
---@field priority? integer the highest that matches is asked (default 0)
---@field match fun(node: Filetree.Node): boolean is this node mine? Table lookups only: it runs on every cursor move while a preview is shown
---@field preview fun(node: Filetree.Node, ctx: Filetree.Preview.Ctx, done: fun(result?: Filetree.Preview.Result, note?: string)): fun()|nil returns at once; `done` once, now or later (`done(nil, "why")` is a note); may return a cancel function

---What `filetree.native.fs.watch` holds, as plain data.
---@class Filetree.Fs.WatchState
---@field recursive boolean one handle per root watches the whole tree below it (Windows, macOS); false: one handle per folder read
---@field watchers { dir: string, refs: integer, error?: string }[] the open handles, sorted by folder; `refs`: how many times the folder was asked for
---@field released { dir: string, refs: integer }[] handles closed for a running file operation, to be opened again after it
---@field quarantined string[] folders held back after an event storm, reported once they went quiet
---@field changed string[] folders whose listing changed and that are not reported yet
---@field stats { events: integer, reports: integer, quarantined: integer } counters since Neovim started

---The state of the file layer of the own tree (`require("filetree").fs_state()`).
---@class Filetree.FsState : Filetree.Fs.WatchState
---@field active boolean the own tree is the active backend (`adapter = "native"`)
---@field watch boolean `native.watch`: false = the tree does not follow the disk, and holds no handle
---@field reading string[] folders being read right now, sorted
---@field roots string[] the roots of the trees there are (one per tab that opened one), sorted

---Something that wants room right of the name.
---@class Filetree.RightItem
---@field text string
---@field width integer display width
---@field slot "badge"|"column"
---@field priority? integer higher survives longer (default 0)
---@field hl? string

---How a line's width is shared out.
---@class Filetree.RightLayout
---@field name_width integer columns left for indent, icon and name
---@field items Filetree.RightItem[] the items that fit, in the order given
---@field dropped integer how many did not fit

return {}
