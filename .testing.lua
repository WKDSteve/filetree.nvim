-- .testing.lua -- configuration of testing.nvim for this project.
-- Written by `testing migrate`; edit freely (it is never overwritten). Every key is optional; the
-- keys are documented in testing.nvim's docs/CONFIG.md. Loading this file executes it (same trust
-- as running the specs).
return {
  -- Lua module root of the project.
  plugin = "filetree",
  -- How the spec files are run: "auto" = sniffed per file, "h" = on the project's own TESTS/harness.lua,
  -- "script" = a self-running script in its own process.
  -- TESTS/sheets_spec.lua is busted style: one case per test sheet (`sheet:<id>`, testing sheets report).
  dialect = { ["TESTS/sheets_spec.lua"] = "busted", ["*"] = "script" },
  -- Lua patterns a file name must match to be a spec (the old runner started these files by name).
  spec_pattern = {
    "_spec%.lua$",
    "^TESTS/smoke%.lua$",
    "^TESTS/units%.lua$",
    "^TESTS/menu%.lua$",
    "^TESTS/cwd_mode%.lua$",
    "^TESTS/sidebar_guard%.lua$",
    "^TESTS/kit_slot%.lua$",
    "^TESTS/gaps%.lua$",
    "^TESTS/env_roots%.lua$",
    "^TESTS/who_locks%.lua$",
    "^TESTS/cheatsheet%.lua$",
    "^TESTS/keys%.lua$",
    "^TESTS/config_schema%.lua$",
    "^TESTS/nav_switch_toggle%.lua$",
    "^TESTS/create_from_template%.lua$",
    "^TESTS/file_clipboard%.lua$",
    "^TESTS/marks_auto_clear%.lua$",
    "^TESTS/marks_order%.lua$",
    "^TESTS/sibling_nav%.lua$",
    "^TESTS/quickpick%.lua$",
    "^TESTS/refs/run%.lua$",
    "^TESTS/refs/usage%.lua$",
    -- Against a REAL neo-tree: CI checks out neo-tree, nui and plenary at pinned commits below
    -- .deps/ (ci.workflow.checkouts); without them each prints an n/a line instead of passing silently.
    "^TESTS/adapter_lines%.lua$",
    "^TESTS/collapse_all_backends%.lua$",
    "^TESTS/group_empty_dirs_collapse%.lua$",
    "^TESTS/neotree_collapse_redraw_coalesce%.lua$",
    "^TESTS/neotree_redraw_hook%.lua$",
    "^TESTS/quickpick_neotree%.lua$",
    "^TESTS/sort_cycle_backends%.lua$",
  },
  -- Dependencies (directory names) put on the runtimepath: $<NAME>_DIR, .deps/<name>, ../<name>,
  -- stdpath('data')/lazy/<name>.
  deps = { "lib.nvim", "ui.nvim", "testing.nvim" },
  -- Guards (fs / state / scheduled_error / prompt / deprecation / process_net) are left at their
  -- defaults. They DO apply to the "script" dialect: testing.nvim's child boot opens ONE guard
  -- window around the whole script file (child/boot.lua, `script_guards` record), so a script spec's
  -- spawns are judged against `guard_allow.spawn` below like any other spec's; there are just no
  -- per-case tags (`@spawn`) in a script, only the config list.
  -- "none" = all specs in one nvim, "file" = one nvim per spec file
  -- (nothing leaks from one file into the next).
  isolated = "none",
  -- Executables the specs start on purpose (matched by basename, `.exe` ignored):
  --   nvim       TESTS/sheets_spec.lua runs every test sheet in a child editor; file_clipboard.lua
  --              uses this very nvim as a harmless stand-in tool.
  --   tar, unzip TESTS/compress_spec.lua creates real archives (`tar -a`) and lists them (`unzip -Z1`).
  --   zip, bsdtar TESTS/compress_spec.lua's real round trip uses whatever archiver.detect() picks:
  --              Info-ZIP `zip` when on PATH (ubuntu/macos runners), else `bsdtar` or `tar`.
  --   sh         TESTS/file_clipboard.lua's non-Windows signal case (`sh -c "kill -9 $$"`).
  --   powershell TESTS/file_clipboard.lua runs the built Windows clipboard command for real.
  --   ft-definitely-missing-tool-xyz  TESTS/file_clipboard.lua checks the "tool not found" path
  --              (the spawn fails by design; nothing is started).
  guard_allow = {
    spawn = {
      "nvim",
      "tar",
      "unzip",
      "zip",
      "bsdtar",
      "sh",
      "powershell",
      -- TESTS/trash_linux_container_spec.lua runs the Linux trash backend in a container (n/a without podman/image).
      "podman",
      "ft-definitely-missing-tool-xyz",
      -- TESTS/native_helper_spec.lua starts the helper process of the own tree (helper/; n/a when not built).
      "filetree-helper",
      -- TESTS/grep_in_dir_fallback_spec.lua runs grep_in_dir's grep fallback for real (rg hidden).
      "grep",
    },
  },
  -- "c" = child started from a -c command (v:vim_did_enter is 0, <cword> works),
  -- "l" = `nvim -l`.
  host = "l",
  -- Environment variables the specs read; a child editor inherits an allowlist only (never secrets).
  env_allow = {
    "FILETREE_ADAPTER_LINES",
    "FILETREE_LIB_NVIM",
    -- TESTS/refs/run.lua: the wait limit and its test hooks (raising the limit on a slow machine
    -- must work through this runner too).
    "FILETREE_REFS_TEST_*",
    "FILETREE_TEST_REAL_CLIPBOARD",
    "FILETREE_UI_NVIM",
    "TESTING_CONTAINER_*",
    -- TESTS/minimal_init_sheet_neotree.lua: where the child editor of a neo-tree test sheet finds
    -- neo-tree and what it needs (else .deps/, ../, the real editor's lazy.nvim directory).
    "NEO_TREE_NVIM_DIR",
    "NUI_NVIM_DIR",
    "PLENARY_NVIM_DIR",
    -- The real-neo-tree suites (adapter_lines.lua, ...): a neo-tree / nvim-tree checkout to use.
    "FILETREE_NEOTREE",
    "FILETREE_NVIMTREE",
    "FT_CODE",
    "FT_X",
    "LIB_NVIM_PATH",
    "UI_NVIM_PATH",
  },
  -- gated: a failed conformance check makes `scripts/test.sh conformance` exit 1 (docs/CONFORMANCE.md of testing.nvim)
  conformance = {
    gate = true,
    waivers = {
      {
        check = "K6",
        level = "warn",
        text = "pdfport.nvim not installed",
        reason = "environment: pdfport.nvim is an optional external plugin absent in the minimal editor; the health line is correct",
        expires = "2027-04-14",
      },
      {
        check = "K10",
        level = "warn",
        reason = "measured ~76-80 ms median (cold fs); the cost is spread over ~100 small modules (setup 45 ms, refs 32, commands 22) with no single heavy require to defer",
        expires = "2027-04-14",
      },
    },
  },
  ci = {
    -- Written out rather than derived: the container image has to be built before the suite starts, and a step of
    -- its own would join `full` after the derived ones.
    profiles = {
      fast = { "stylua", "luacheck" },
      full = {
        "fast",
        "container-image",
        "suite",
        "conformance",
        "doc-reference",
        "workflow-in-sync",
      },
    },
    default = "full",
    steps = {
      -- TESTS/trash_linux_container_spec.lua runs the Linux trash backend in a container (testing.container); the
      -- hosted ubuntu leg builds the image here (red there without podman), elsewhere the step only reports.
      ["container-image"] = {
        run = { "scripts/ci-container-image.sh", "${deps.testing.nvim}" },
        when = { os = { "linux" } },
        timeout = "15m",
      },
      -- The FEATURE REFERENCE section of doc/filetree.txt is generated from docs/FEATURES/*.md and the binding
      -- catalog: a new feature without its `:help filetree-<it>` entry is red. It loads the plugin, hence lib.nvim.
      ["doc-reference"] = {
        run = {
          "nvim",
          "-n",
          "--clean",
          "--headless",
          "-u",
          "NONE",
          "-l",
          "scripts/gen_vimdoc_reference.lua",
          "--check",
        },
        env = { FILETREE_LIB_NVIM = "${deps.lib.nvim}" },
      },
      ["workflow-in-sync"] = { preset = "workflow-in-sync" },
    },
    -- The GitHub workflow, generated: `testing init --workflow=public --force` writes .github/workflows/ci.yml from
    -- this (testing.nvim docs/WORKFLOW-CI.md); the step workflow-in-sync keeps the two together.
    workflow = {
      name = "filetree.nvim",
      layout = "hosted",
      -- the steps that depend on the platform: the windows and macOS legs run only these
      platform = { "suite", "conformance" },
      -- `testing ci land`: a check branch ci/** runs the hosted legs, main moves to a commit only once it is green there
      land = true,
      -- more checkouts below .deps/, not on the runtimepath of the specs. TESTS/neotree_pins.lua reads these pins from
      -- the generated .github/workflows/ci.yml (`repository:` + a 40-hex `ref:` per step): the real-neo-tree suites use
      -- a checkout they find on their own only at these commits.
      checkouts = {
        {
          repo = "nvim-neo-tree/neo-tree.nvim",
          ref = "1a14083046d96e88e361d1da00761c40d45012f3",
          why = "the real-neo-tree suites (adapter_lines.lua, ...) and the test sheet diag-badges-neotree",
        },
        {
          repo = "MunifTanjim/nui.nvim",
          ref = "10fc361835c856ba4233ef5ea135b919bf3dce97",
          why = "a hard dependency of neo-tree.nvim in the real-neo-tree suites and sheets",
        },
        {
          repo = "nvim-lua/plenary.nvim",
          ref = "74b06c6c75e4eeb3108ec01852001636d85a932b",
          why = "a hard dependency of neo-tree.nvim in the real-neo-tree suites and sheets",
        },
      },
      publish = { why = "hover.nvim checks out filetree.nvim at ci-verified (its test sheets)" },
    },
  },
}
