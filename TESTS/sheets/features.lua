-- TESTS/sheets/features.lua -- the functionalities of the own tree (`adapter = "native"`) as its reader meets them;
-- `testing sheets report` says which ones have a feature sheet (`feature = "<id>"`) and in which state, and K16 warns
-- about a sheet that names an id not listed here. Data: read with an empty environment like a sheet (testing.nvim
-- docs/SHEETS.md). The why of each one is in docs/FEATURES/BACKENDS.md.
return {
  {
    id = "filetree.native-sticky-parents",
    title = "While the tree is scrolled, the folders the top row lies in stay pinned on top",
    surface = { "config:native.sticky_parents" },
    docs = "docs/FEATURES/BACKENDS.md",
  },
  {
    id = "filetree.native-root-history",
    title = "<BS> and g<BS> go back and forward through the roots shown, E opens every folder below one up to a cap",
    surface = {
      "binding:<BS>",
      "binding:g<BS>",
      "binding:-",
      "binding:E",
      "config:native.expand_all_max",
    },
    docs = "docs/FEATURES/BACKENDS.md",
  },
  {
    id = "filetree.native-views",
    title = "The tree shows views (files, buffers, git ...) and a bar of them in its winbar",
    surface = { "config:native.views", "config:native.view_bar" },
    docs = "docs/FEATURES/BACKENDS.md",
  },
  {
    id = "filetree.native-current-marker",
    title = "The active buffer's row carries a marker one level in from its folder's arrow, or none",
    surface = { "config:features.current_hl.icon", "config:features.current_hl.icon_hl" },
    docs = "docs/FEATURES/UI.md",
  },
  {
    id = "filetree.native-ai",
    title = ":Filetree ask turns a sentence into actions of the tree, and asks before one that changes files",
    surface = { "command:Filetree ask", "config:native.ai" },
    docs = "docs/FEATURES/AI.md",
  },
  {
    id = "filetree.native-helper",
    title = "The helper process lists, sizes and watches for the tree, and the Lua tiers take over when it ends",
    surface = { "config:native.fs.helper" },
    docs = "docs/FEATURES/BACKENDS.md",
    -- the program is built by cargo or downloaded from a release (helper.yml); neither a sheet's
    -- sandbox nor ci.yml has it, and a feature sheet that skips without it is red on CI
    perf = "manual:needs the built filetree-helper program, which the sheets' sandbox and ci.yml do not have",
  },
  {
    id = "filetree.helper-build",
    title = ":Filetree helper build builds or downloads the helper program in the background, cancellable",
    surface = { "command:Filetree helper build", "command:Filetree helper cancel" },
    docs = "docs/FEATURES/BACKENDS.md",
  },
  {
    id = "filetree.system-open",
    title = "A node opens in the system's default application (<leader>sm, preview of system_exts, a PDF without pdfport)",
    surface = { "config:features.open_with.keymap", "config:features.preview.system_exts" },
    -- lib.nvim.cross.open_default starts explorer.exe / rundll32.exe on Windows by their .exe names,
    -- which a sheet's stand-in (a .cmd file there) cannot catch: a sheet would open real windows
    perf = "manual:on Windows the opener is explorer.exe/rundll32.exe, which no stand-in catches; a sheet would open a real window",
  },
  {
    id = "filetree.open-in-fm",
    title = "<leader>fm shows the node under the cursor in the file manager",
    surface = { "config:features.open_in_fm.command" },
  },
  {
    id = "filetree.open-with",
    title = "A key of the user's list of applications opens the node under the cursor with that application",
    surface = { "config:features.open_with.apps" },
  },
  {
    id = "filetree.shell-run",
    title = "i runs a shell command in the folder of the node under the cursor, in a terminal split",
    surface = { "config:features.shell_run.keymap" },
  },
  {
    id = "filetree.compress",
    title = "gz compresses the node under the cursor (or the marked ones) to a zip beside it",
    surface = { "command:Filetree compress", "config:features.compress.keymap" },
  },
  {
    id = "filetree.grep-in-dir",
    title = "gr searches the text below the folder under the cursor into the quickfix list (or a picker)",
    surface = { "command:FiletreeGrepInDir", "config:features.grep_in_dir.prefer" },
  },
  {
    id = "filetree.git-status",
    title = "Each row of the tree carries the git state of its file as a sign, a folder the worst below it",
    surface = { "config:features.git_status.signs" },
  },
  {
    id = "filetree.native-git-view",
    title = "The view git of the own tree groups the changed files, ga stages and gu unstages the one under the cursor",
    surface = { "config:native.views" },
    docs = "docs/FEATURES/BACKENDS.md",
  },
  {
    id = "filetree.trash",
    title = "d moves the node under the cursor (or the marked ones, in one process) to the system trash, U brings the last one back",
    surface = { "config:features.trash.keymap", "config:features.trash.keymap_undo" },
  },
  {
    id = "filetree.size-info",
    title = "A column shows the size of each file, and of each folder once a process has added it up",
    surface = { "command:FiletreeSizeRefresh", "config:features.size_info.show_dirs" },
  },
}
