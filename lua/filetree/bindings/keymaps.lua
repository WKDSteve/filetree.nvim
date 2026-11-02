---@module 'filetree.bindings.keymaps'
--- Catalog of default keymaps, grouped by feature category.
---
--- Reference catalog of the keymaps filetree.nvim binds out of the box. It mirrors
--- the per-feature defaults (which remain the runtime source of truth and stay
--- user-configurable). Used for the `docs/BINDINGS.lua` cheatsheet and the
--- optional which-key integration.
---
--- Each entry: { lhs, desc, feature, scope = "tree"|"global", opt_in? = true }
---   scope "tree"   — buffer-local in the tree window
---   scope "global" — normal-mode, everywhere
---   opt_in         — feature is disabled by default (see DEFAULT_DISABLED)

---@class FiletreeBinding
---@field lhs     string
---@field desc    string
---@field feature string
---@field scope   "tree"|"global"
---@field opt_in? boolean

---@type table<string, FiletreeBinding[]>
return {
  nav = {
    { lhs = "-", desc = "Parent directory (up)", feature = "tree_traverse", scope = "tree" },
    {
      lhs = "W",
      desc = "Collapse all folders back to the root",
      feature = "collapse_all",
      scope = "tree",
    },
    {
      lhs = "<leader>so",
      desc = "Next sort criterion (name, size, modified)",
      feature = "sort_cycle",
      scope = "tree",
    },
    {
      lhs = "<leader>sO",
      desc = "Reverse the sort",
      feature = "sort_cycle",
      scope = "tree",
    },
    {
      lhs = "+",
      desc = "Set dir under cursor as root",
      feature = "tree_traverse",
      scope = "tree",
    },
    {
      lhs = "]s",
      desc = "Next sibling (same depth)",
      feature = "tree_traverse",
      scope = "tree",
    },
    {
      lhs = "[s",
      desc = "Previous sibling (same depth)",
      feature = "tree_traverse",
      scope = "tree",
    },
    { lhs = "B", desc = "Reveal alternate buffer (#)", feature = "reveal_alt", scope = "tree" },
    {
      lhs = "L",
      desc = "Cycle cwd mode (follow/project/lock)",
      feature = "cwd_mode",
      scope = "tree",
    },
    {
      lhs = "gp",
      desc = "Lock cwd to the node under the cursor",
      feature = "cwd_mode",
      scope = "tree",
    },
    {
      lhs = "<C-n>",
      desc = "Next buffer in adjacent editor window",
      feature = "buffer_cycle",
      scope = "tree",
    },
    {
      lhs = "<C-p>",
      desc = "Previous buffer in adjacent editor window",
      feature = "buffer_cycle",
      scope = "tree",
    },
    {
      lhs = '"',
      desc = "Next neo-tree source, keeping the tree's position",
      feature = "source_switcher",
      scope = "tree",
    },
    {
      lhs = "!",
      desc = "Previous neo-tree source, keeping the tree's position",
      feature = "source_switcher",
      scope = "tree",
    },
    {
      lhs = "<M-c>",
      desc = "Toggle the tree in the current window (reveal)",
      feature = "tree_toggle",
      scope = "global",
      opt_in = true,
    },
    {
      lhs = "<M-f>",
      desc = "Toggle the tree as a float (reveal)",
      feature = "tree_toggle",
      scope = "global",
      opt_in = true,
    },
    {
      lhs = "<M-l>",
      desc = "Toggle the tree on the left (reveal)",
      feature = "tree_toggle",
      scope = "global",
      opt_in = true,
    },
    {
      lhs = "<M-r>",
      desc = "Toggle the tree on the right (reveal)",
      feature = "tree_toggle",
      scope = "global",
      opt_in = true,
    },
    {
      lhs = "<leader>;",
      desc = "Numbered quick-pick: number the tree entries, type a number to open (a count roots the tree above the file)",
      feature = "quickpick",
      scope = "global",
      opt_in = true,
    },
    {
      lhs = "<leader>:",
      desc = "Numbered quick-pick with the tree rooted at the cwd",
      feature = "quickpick",
      scope = "global",
      opt_in = true,
    },
  },
  ui = {
    {
      lhs = "<Tab>",
      desc = "Preview toggle; image/PDF dispatch",
      feature = "preview",
      scope = "tree",
    },
    {
      lhs = "<CR>",
      desc = "Image/PDF dispatch; else adapter default",
      feature = "preview",
      scope = "tree",
    },
    {
      lhs = "<C-b>",
      desc = "Scroll float preview up (×count)",
      feature = "preview",
      scope = "tree",
    },
    {
      lhs = "<C-f>",
      desc = "Scroll float preview down (×count)",
      feature = "preview",
      scope = "tree",
    },
    {
      lhs = "<PageUp>",
      desc = "Page float preview up 10 (×count); pages buffer-mode preview natively",
      feature = "preview",
      scope = "tree",
    },
    {
      lhs = "<PageDown>",
      desc = "Page float preview down 10 (×count); pages buffer-mode preview natively",
      feature = "preview",
      scope = "tree",
    },
    { lhs = "I", desc = "Node info float", feature = "node_info", scope = "tree" },
    { lhs = "w", desc = "Cycle window size", feature = "window_size_cycler", scope = "tree" },
    {
      lhs = "<Esc>",
      desc = "Reset preview + filter + search",
      feature = "tree_reset",
      scope = "tree",
    },
    {
      lhs = "?",
      desc = "Paged cheatsheet: filetree keys, other keys, commands",
      feature = "cheatsheet",
      scope = "tree",
    },
    {
      lhs = "<RightMouse>",
      desc = "Open context menu via ui.contextmenu (nvzone/menu or its kit renderer)",
      feature = "context_menu",
      scope = "tree",
    },
  },
  fileops = {
    { lhs = "a", desc = "Smart create file/dir", feature = "smart_create", scope = "tree" },
    { lhs = "c", desc = "Stage node for copy", feature = "copy_move", scope = "tree" },
    { lhs = "x", desc = "Stage node for cut", feature = "copy_move", scope = "tree" },
    { lhs = "p", desc = "Paste staged nodes", feature = "copy_move", scope = "tree" },
    { lhs = "P", desc = "Show copy/cut clipboard", feature = "copy_move", scope = "tree" },
    {
      lhs = "X",
      desc = "Clear copy/cut clipboard",
      feature = "copy_move",
      scope = "tree",
    },
    { lhs = "<leader>rb", desc = "Batch rename buffer", feature = "rename_batch", scope = "tree" },
    { lhs = "r", desc = "Rename with LSP refs", feature = "smart_rename", scope = "tree" },
    {
      lhs = "A",
      desc = "Create from template (pick template first, then pre-filled filename)",
      feature = "create_from_template",
      scope = "tree",
    },
    { lhs = "O", desc = "Open (replace buffer)", feature = "open_replace", scope = "tree" },
    {
      lhs = "<M-CR>",
      desc = "Open (swap: close focused buffer, keep its slot)",
      feature = "open_replace",
      scope = "tree",
    },
    {
      lhs = "<C-CR>",
      desc = "Open (swap) — only in terminals that send <C-CR>",
      feature = "open_replace",
      scope = "tree",
    },
    { lhs = "sg", desc = "Open in vertical split", feature = "open_variants", scope = "tree" },
    { lhs = "sv", desc = "Open in horizontal split", feature = "open_variants", scope = "tree" },
    { lhs = "st", desc = "Open in new tab", feature = "open_variants", scope = "tree" },
    {
      lhs = "gb",
      desc = "Add to buffer list (no focus switch)",
      feature = "open_variants",
      scope = "tree",
    },
    {
      lhs = "<S-CR>",
      desc = "Collapse directory (else add to buffer list, no focus switch)",
      feature = "open_variants",
      scope = "tree",
    },
    { lhs = "d", desc = "Trash current node (or marked)", feature = "trash", scope = "tree" },
    { lhs = "U", desc = "Undo last trash operation", feature = "trash", scope = "tree" },
    { lhs = "<leader>th", desc = "Show trash history", feature = "trash", scope = "tree" },
    { lhs = "<C-s>", desc = "Save adjacent buffer", feature = "buffer_save", scope = "tree" },
    { lhs = "<M-s>", desc = "Save node buffer", feature = "buffer_save", scope = "tree" },
  },
  search = {
    { lhs = "/", desc = "Filter tree", feature = "filter", scope = "tree" },
    {
      lhs = "<C-c>",
      desc = "Clear applied filter",
      feature = "filter",
      scope = "tree",
    },
    { lhs = "gs", desc = "Live search", feature = "live_search", scope = "tree" },
    { lhs = "f", desc = "Find files", feature = "find_files", scope = "tree" },
    {
      lhs = "tf",
      desc = "Find files via pickers.nvim specifically",
      feature = "find_files",
      scope = "tree",
    },
    { lhs = "gr", desc = "Grep in dir", feature = "grep_in_dir", scope = "tree" },
    {
      lhs = "tg",
      desc = "Grep via pickers.nvim specifically",
      feature = "grep_in_dir",
      scope = "tree",
    },
  },
  paths = {
    { lhs = "[a", desc = "Copy absolute path", feature = "path_copy", scope = "tree" },
    { lhs = "]a", desc = "Copy absolute parent directory", feature = "path_copy", scope = "tree" },
    {
      lhs = "]b",
      desc = "Copy path relative to the open buffer (./x, ../x)",
      feature = "path_copy",
      scope = "tree",
    },
    {
      lhs = "[e",
      desc = "Copy path with an env-var root ($REPOS_DIR/…)",
      feature = "path_copy",
      scope = "tree",
    },
    {
      lhs = "rq",
      desc = 'Copy as require("…")',
      feature = "lua_require_copy",
      scope = "tree",
    },
    {
      lhs = "<leader>sp",
      desc = "Spotlight the node's name (spotlight.nvim)",
      feature = "spotlight_node",
      scope = "tree",
    },
    { lhs = "[f", desc = "Copy file list (abs)", feature = "copy_file_list", scope = "tree" },
    { lhs = "]f", desc = "Copy file list (rel)", feature = "copy_file_list", scope = "tree" },
    { lhs = "[F", desc = "Copy dir list (abs)", feature = "copy_file_list", scope = "tree" },
    { lhs = "]F", desc = "Copy dir list (rel)", feature = "copy_file_list", scope = "tree" },
    {
      lhs = "ML",
      desc = "Markdown link for current node",
      feature = "markdown_links",
      scope = "tree",
    },
    {
      lhs = "MR",
      desc = "Markdown links recursively",
      feature = "markdown_links",
      scope = "tree",
    },
    {
      lhs = "MM",
      desc = "Markdown links from marked",
      feature = "markdown_links",
      scope = "tree",
    },
    {
      lhs = "MI",
      desc = "Insert markdown link(s) into the editor window",
      feature = "markdown_links",
      scope = "tree",
    },
  },
  git = {},
  org = {
    { lhs = "m", desc = "Toggle mark", feature = "marks", scope = "tree" },
    { lhs = "]m", desc = "Mark all visible", feature = "marks", scope = "tree" },
    { lhs = "[m", desc = "Unmark all visible", feature = "marks", scope = "tree" },
    { lhs = "<leader>mc", desc = "Clear all marks", feature = "marks", scope = "tree" },
    { lhs = "<leader>ms", desc = "Show marked nodes", feature = "marks", scope = "tree" },
    { lhs = "gm", desc = "Go to Nth marked node (×count)", feature = "marks", scope = "tree" },
    { lhs = "]M", desc = "Next marked node", feature = "marks", scope = "tree" },
    { lhs = "[M", desc = "Previous marked node", feature = "marks", scope = "tree" },
  },
  system = {
    {
      lhs = "<leader>fm",
      desc = "Open dir in file manager",
      feature = "open_in_fm",
      scope = "tree",
    },
    {
      lhs = "<leader>sm",
      desc = "Open with system default",
      feature = "open_with",
      scope = "tree",
    },
    {
      lhs = "gy",
      desc = "Copy file(s) to the system clipboard (paste with Ctrl+V elsewhere)",
      feature = "file_clipboard",
      scope = "tree",
    },
    { lhs = "i", desc = "Run shell command in dir", feature = "shell_run", scope = "tree" },
    {
      lhs = "go",
      desc = "Open PDF (pdfport; default_mode picks the viewer)",
      feature = "pdf_open",
      scope = "tree",
    },
    {
      lhs = "gP",
      desc = "Create PDF from node/marks/folder (pdfport, confirms first)",
      feature = "pdf_create",
      scope = "tree",
    },
    {
      lhs = "gz",
      desc = "Compress node/marked nodes to .zip",
      feature = "compress",
      scope = "tree",
    },
  },
  lsp = {},
  compare = {
    { lhs = "D", desc = "Diff current node", feature = "diff", scope = "tree" },
  },
}
