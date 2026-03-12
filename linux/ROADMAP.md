# cmux Linux Port Roadmap

## Origin Story

This Linux port started as a conversation between a human (Matt) and an AI agent (Claude) about bringing cmux — a macOS terminal multiplexer built on Ghostty — to Linux using GTK4 and Zig. During the process of building the socket API and testing `surface.send_text`, we realized something: **this is exactly the kind of tool an AI coding agent needs**.

Right now, when I (Claude) work through Claude Code, I run commands through a stateless Bash tool — fire a command, get stdout back, done. No persistent sessions, no parallel workflows, no ability to interact with running processes. With cmux's socket API, I could maintain terminal sessions, split panes for parallel work, monitor long-running processes, and drive interactive programs — the way a human developer actually works.

So this roadmap is written from the perspective of an AI agent who is both the builder and the first user. The question driving prioritization is: **"What do I need to start dogfooding cmux as my own development environment?"**

---

## What We Started With

- The macOS cmux app: a full-featured terminal multiplexer wrapping Ghostty, with SwiftUI, split panes, workspaces, a browser panel, 80+ socket API methods, session persistence, notifications, shell integration, Claude Code integration, and 19-language localization.
- A Linux machine with GTK4, Zig 0.14, and a Ghostty fork with embedded apprt support.
- No Linux code at all.

---

## What's Complete (Phases 0-5)

### Phase 0-1: Ghostty Embedded Apprt on Linux
- [x] Fork Ghostty with Linux platform in embedded apprt (`PlatformTag.linux`, `must_draw_from_app_thread`)
- [x] Move glad (OpenGL loader) compilation out of exe-only block so lib builds get GL support
- [x] OpenGL context initialization for Linux embedded surfaces
- [x] GTK4 application with GtkGLArea rendering Ghostty surfaces
- [x] Full keyboard input (key-pressed/key-released with modifier translation)
- [x] Full mouse input (click, scroll, motion for all buttons)
- [x] HiDPI scale factor support
- [x] Surface registry pattern for safe surface-to-widget lookup (avoids GTK-CRITICAL errors)
- [x] GObject reference counting to prevent premature widget finalization

### Phase 2: Split Panes
- [x] Binary split tree data structure (PaneTree) with horizontal/vertical splits
- [x] Split in all four directions (right, down, left, up)
- [x] Close pane with sibling promotion
- [x] Navigate focus across panes (left/right/up/down)
- [x] Resize splits (data model — divider_position with 0.05-0.95 clamping)
- [x] Swap panes
- [x] Layout calculation (proportional pixel rect computation)
- [x] GtkPaned widget tree construction from PaneTree model

### Phase 3: Workspace Sidebar
- [x] Multiple workspaces with TabManager (create/switch/close/rename/reorder)
- [x] Sidebar with GtkListBox showing workspace titles and subtitles
- [x] Subtitle shows git branch if set, otherwise pane count
- [x] Workspace navigation (next/previous, click-to-select)
- [x] Workspace history stack for "last workspace" navigation
- [x] Toggle sidebar visibility

### Phase 4: Socket Protocol Server
- [x] Unix domain socket server at `/tmp/cmux.sock`
- [x] Newline-delimited JSON-RPC protocol
- [x] Background accept thread + per-client handler threads
- [x] 16 V2 methods implemented:
  - `system.ping`, `system.identify`, `system.capabilities`, `system.tree`
  - `workspace.list`, `workspace.create`, `workspace.current`, `workspace.select`, `workspace.close`, `workspace.rename`
  - `surface.list`, `surface.current`, `surface.send_text`
  - `pane.list`
  - `window.list`, `window.current`
- [x] Handle registry for ref-string generation

### Phase 5: CLI Tool
- [x] Standalone `cmux-cli` binary (no GTK dependency, libc only)
- [x] All 41 socket methods exposed as CLI commands
- [x] Socket path from `CMUX_SOCKET` / `CMUX_SOCKET_PATH` / default `/tmp/cmux.sock`
- [x] JSON response output
- [x] Agent-critical commands: `surface read-text`, `surface send-key`, `surface split`, `surface close`, `pane resize`, `pane swap`

### Bug Fixes
- [x] GTK-CRITICAL `gtk_gl_area_queue_render` assertion flood — fixed with realized flag, surface registry, GObject ref counting, onUnrealize callback
- [x] `surface.send_text` commands appearing but not executing — switched from `ghostty_surface_text` (bracketed paste) to `ghostty_surface_binding_action("text:...")` (direct PTY write)
- [x] Terminal resize not working on Linux — Ghostty's resize handling had a Darwin-specific clause; patched in fork and updated libghostty binary
- [x] `set_title` crash on Linux — fixed alongside resize patch
- [x] Sidebar workspace click stealing keyboard focus from terminal — made GtkListBox non-focusable and reordered syncSelection before terminal focus in switchWorkspace

---

## The Dogfooding Roadmap

### Priority 1: "Can I use this terminal at all?" (Basic Usability) ✅ COMPLETE

All basic usability items are implemented and working.

- [x] **Clipboard read (paste)** — Full GDK4 async clipboard with proper threading (g_idle_add dispatch from Ghostty thread to GTK main thread). Supports both standard (Ctrl+Shift+V) and primary selection (middle-click).

- [x] **Ghostty action callbacks** — Implemented `set_title`, `close_surface`, `new_split`, `cell_size`, `pwd`, `close_window`. All dispatched to GTK main thread via g_idle_add.

- [x] **Working directory per terminal** — Workspace stores cwd in a buffer. New splits and workspaces inherit parent's cwd. Ghostty's PWD action callback feeds cwd updates.

- [x] **Socket `workspace.select` GTK widget switching** — Socket handlers now dispatch GTK widget operations (select, create, close) to the main thread via g_idle_add.

- [x] **Split divider positioning** — Uses GtkPaned `realize` signal to query actual widget allocation and set proportional divider position.

### Priority 2: "Can I drive this programmatically?" (Agent Essentials) ✅ COMPLETE

All agent essential socket methods are implemented. Total API methods: 25.

- [x] **`surface.read_text`** — Reads terminal content via `ghostty_surface_read_text`. Uses `std.Thread.ResetEvent` to synchronously dispatch to GTK main thread. Supports `scrollback` param for full scrollback buffer.

- [x] **`surface.split` via socket** — Creates splits with `direction` param (left/right/up/down). Dispatches `window.splitFocused()` via g_idle_add.

- [x] **`surface.close` via socket** — Closes focused pane via socket. Guards against closing last pane.

- [x] **`surface.send_key` via socket** — Sends named keystrokes (ctrl-c, enter, tab, arrow keys, escape, etc.) via `ghostty_surface_binding_action` with escape sequences.

- [x] **`pane.resize` via socket** — Adjusts split divider position. New `Window.syncDividerPositions` method updates GtkPaned widgets to match data model.

- [x] **`pane.swap` via socket** — Swaps two panes. New `Window.rebuildCurrentWorkspace` rebuilds GTK widget tree reusing existing TerminalWidget instances.

- [x] **`workspace.next` / `workspace.previous` / `workspace.last` via socket** — Quick navigation reusing existing WorkspaceSwitchCtx pattern and TabManager methods.

- [x] **Environment variables per surface** — New terminals get `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, `CMUX_SOCKET_PATH` via `ghostty_env_var_s` in surface config.

### Priority 3: "Can I maintain state across sessions?" (Persistence) ✅ COMPLETE

All persistence items are implemented and working.

- [x] **Session save** — Auto-saves workspace layout, titles, pane tree structure, working directories, and split divider positions to `~/.config/cmux/session.json` every 8 seconds via `g_timeout_add_seconds`. Also saves on clean shutdown. Uses atomic write (tmp file + rename) for crash safety.

- [x] **Session restore** — On launch, reads `session.json` and rebuilds all workspaces, pane trees (including nested splits), titles, cwd, pinned state, focused pane, and node ID counters. Falls back to a fresh default workspace if the file is missing, corrupt, or version-mismatched. Disabled with `CMUX_DISABLE_SESSION_RESTORE=1`.

- [x] **Ghostty config integration** — Ghostty's own config system loads `~/.config/ghostty/config` automatically via `ghostty_config_load_default_files` in `app.zig`. Fonts, colors, and themes are applied to all surfaces without additional code. No further integration needed for basic use.

### Priority 4: "Can I stay aware of what's happening?" (Observability) ✅ COMPLETE

All observability items are implemented and working. Total API methods: 34.

- [x] **Shell integration scripts** — Bash (`cmux-bash-integration.bash`) and Zsh (`cmux-zsh-integration.zsh`) scripts that hook into the prompt cycle. Report git branch and dirty status to cmux via V2 JSON-RPC over the Unix socket. Only send when values change (deduplication). Activate automatically when `CMUX_WORKSPACE_ID` is set.

- [x] **Sidebar richness** — Enhanced workspace sidebar rows now show:
  - Git branch with dirty indicator (`main *` for dirty, `main` for clean)
  - Status metadata entries (`key: value | key: value` format)
  - GtkProgressBar with optional label (fraction 0.0-1.0)
  - Most recent log entry (prefixed with `>`)
  - Each row dynamically renders only the metadata that exists

- [x] **Workspace metadata socket methods** — 6 new methods:
  - `workspace.report_git` — set git branch + dirty flag
  - `workspace.set_status` / `workspace.clear_status` — key-value status entries
  - `workspace.add_log` / `workspace.clear_log` — log entry ring buffer
  - `workspace.set_progress` — progress bar (0=hidden, 0.01-1.0=visible) with optional label
  - All methods trigger sidebar row update via `g_idle_add`

- [x] **Desktop notifications** — Via libnotify on Linux. `notify_init`/`notify_uninit` lifecycle in main.zig.

- [x] **Notification socket methods** — 3 new methods:
  - `notification.create` — store + show desktop notification via libnotify
  - `notification.list` — list stored notifications (64-entry ring buffer, most recent first)
  - `notification.clear` — clear one or all notifications

### Priority 5: "Can I organize complex workflows?" (Power Features) ✅ COMPLETE

All power features are implemented and working. Total API methods: 41.

- [x] **GTK CSS provider** — Application-wide CSS loaded at startup via `GtkCssProvider`. Defines workspace accent color classes (8 colors), command palette styles, and search overlay styles.

- [x] **Workspace pinning** — Pin workspaces to the top of the sidebar via `workspace.set_pinned`. Two-pass sidebar rebuild (pinned first, then unpinned). Uses `g_object_set_data`/`g_object_get_data` for real workspace index tracking on GtkListBoxRows.

- [x] **Workspace colors** — 8-color accent palette (red, blue, green, yellow, purple, orange, pink, cyan). Sidebar rows show a 4px colored accent bar. Persisted in session. Set via `workspace.set_color`.

- [x] **Command palette** — GtkSearchEntry + GtkListBox overlay with 11 registered actions. Case-insensitive substring fuzzy matching. Arrow key navigation, Enter to execute, Escape to dismiss. Ctrl+Shift+P shortcut. Socket API: `command_palette.list`, `command_palette.execute`.

- [x] **Terminal find/search** — Search overlay with GtkSearchEntry + match count label + close button. Integrates with Ghostty's search API (`search:forward`, `search:next`, `search:prev`, `search:close`). Match count updated via action callbacks. Ctrl+Shift+F shortcut. Socket API: `surface.search`.

- [x] **Pane break/join** — Detach a pane from its current workspace and move it to a new workspace (`pane.break`) or an existing workspace (`pane.join`). Uses `PaneTree.detachPane` for safe removal with sibling promotion and `attachPaneAsRoot` for insertion.

### Phase 6: Dogfooding Readiness ✅ COMPLETE

The CLI tool now covers all 41 socket methods — no gaps between what the socket can do and what the CLI exposes. An agent configuration file (`linux/CLAUDE.md`) provides persistent instructions so future sessions know to use `cmux-cli` for development workflows.

- [x] **Complete CLI coverage** — Added 6 missing commands: `surface read-text` (with `--scrollback` flag), `surface send-key`, `surface split`, `surface close`, `pane resize` (with optional amount), `pane swap`. The CLI now has a 1:1 mapping with all socket API methods.
- [x] **Agent instructions** — Created `linux/CLAUDE.md` with usage examples for all cmux-cli commands, workflow patterns (parallel splits, workspace management, observability), and architecture notes. This file is auto-loaded by Claude Code when working in the `linux/` directory.

To start dogfooding: copy `zig-out/bin/cmux-cli` to PATH, launch `zig-out/bin/cmux`, and start a new agent session.

### Priority 6: "Feature parity with macOS" (Long Tail)

These are significant features from macOS that would be valuable but aren't blocking basic use:

- [ ] **Multi-window** — Multiple independent GTK windows, each with their own workspace set. Requires deep refactoring of single-window architecture (global_window, socket handler dispatch, session persistence).

- [ ] **Browser panel** — Embedded web browser (WebKitGTK on Linux). The macOS version has 80+ automation API methods. This is essentially a separate product.

- [ ] **Markdown panel** — Render local markdown files in a pane.

- [x] **Claude Code integration** — Session tracking, sidebar status via `claude.hook` socket method. Wrapper script (`Resources/bin/claude`) detects Linux and uses `cmux-cli`. In-memory session store maps session IDs to workspaces. Sidebar shows classified status (Running/Permission/Error/Waiting/Attention). Desktop notifications on stop and notification events. CLI supports `--socket` flag and `claude-hook` subcommand with stdin JSON parsing.

- [ ] **Port scanner** — Detect TCP listening ports per terminal pane.

- [ ] **Open-in-IDE** — Open current directory in VS Code, Zed, etc.

- [ ] **Tmux compatibility shims** — CLI commands that translate tmux syntax.

- [ ] **V1 text protocol** — The macOS app supports both V1 (text) and V2 (JSON) protocols. We only have V2.

- [ ] **Socket control modes** — Auth levels (cmux-only, automation, password, allow-all).

- [ ] **Localization** — The macOS app supports 19 languages.

- [ ] **Auto-update** — Package manager integration or self-update mechanism.

- [ ] **Configurable settings UI** — A settings window for all the options currently hardcoded.

---

## Architecture Notes

- **Language:** Zig (targeting 0.14), using `@cImport` for GTK4 and Ghostty C headers
- **UI toolkit:** GTK4 (GtkApplication, GtkGLArea, GtkPaned, GtkListBox, etc.)
- **Terminal backend:** Ghostty embedded apprt via `libghostty.so`
- **Ghostty fork:** `mattmorganpdx/ghostty` branch `matt/linux-embedded-apprt` — adds Linux platform to embedded apprt
- **Socket:** Unix domain socket at `/tmp/cmux.sock`, JSON-RPC protocol, thread-per-client
- **Build:** `zig build` produces `cmux` (GUI) and `cmux-cli` (socket client)

---

## Current State

As of 2026-03-12: The Linux port is ready for dogfooding with Claude Code integration. 42 socket API methods (41 original + `claude.hook`) have matching CLI commands. The `cmux-cli` binary supports `--socket` flag for explicit socket path override. Agent instructions are configured via `linux/CLAUDE.md`.

An AI agent can: read terminal output, send commands and keystrokes, create/close splits, navigate workspaces, resize/swap panes, discover its own terminal context via environment variables, have its workspace layout survive restarts, feed metadata into the sidebar, receive desktop notifications, use the command palette API, search terminal content, color-code and pin workspaces, reorganize panes across workspaces, and have Claude Code session status automatically reflected in the sidebar — all through the socket API or `cmux-cli`.

Phases 0-6 are complete plus Claude Code integration from Priority 6. Remaining Priority 6 items (long tail feature parity with macOS) are next.
