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
  },
}
