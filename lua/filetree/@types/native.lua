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
---@field lazy? boolean the node has children the source answers through its `children(node, ctx, cb)`

---What a source, a decorator or an action is called with.
---@class Filetree.Ctx
---@field root string the root directory of the view
---@field cwd string
---@field win integer the tree window
---@field view string the name of the view shown in it
---@field source? string the source the node in question came from
---@field alt_buf? integer the editor buffer the tree was opened from

---@class Filetree.Emit : Lib.Tree.Registry.Emit

---Supplies the nodes of one view.
---@class Filetree.Source : Lib.Tree.Registry.Source
---@field root fun(ctx: Filetree.Ctx): Filetree.Node
---@field children? fun(node: Filetree.Node, ctx: Filetree.Ctx, cb: fun(list?: Filetree.Node[], err?: string)) asked for the root when it carries no `children`, and for a node with `lazy = true`; answers like a node's own `children`
---@field mutable? boolean false: the nodes of this source are not to be changed (actions that need "mutable" step back)
---@field subscribe? fun(ctx: Filetree.Ctx, emit: Filetree.Emit): fun()
---@field actions? Filetree.Action[]
---@field preview? fun(node: Filetree.Node, ctx: Filetree.Ctx): table|nil

---@class Filetree.Badge : Lib.Tree.Registry.Badge

---Badges on nodes. `get` runs while the tree draws: a table lookup, never I/O.
---@class Filetree.Decorator : Lib.Tree.Registry.Decorator
---@field get fun(key: string, node?: Filetree.Node): Filetree.Badge|nil  `node` is given while a row is drawn, not when a changed key is re-read
---@field all? fun(): table<string, Filetree.Badge> every key with a badge; needed for a folder to show what lies below it

---@class Filetree.ActionArg : Lib.Tree.Registry.ActionArg

---Something to do with the node under the cursor, or with the selection. One table feeds the keys, the
---cheatsheet, the context menu and `:Filetree`.
---@class Filetree.Action : Lib.Tree.Registry.Action
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
