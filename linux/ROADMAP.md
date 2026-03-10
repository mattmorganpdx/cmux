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
- [x] Standalone `cmux-cli` binary (no GTK dependency)
- [x] 16 commands mirroring all socket methods
- [x] Socket path from `CMUX_SOCKET` / `CMUX_SOCKET_PATH` / default `/tmp/cmux.sock`
- [x] JSON response output

### Bug Fixes
- [x] GTK-CRITICAL `gtk_gl_area_queue_render` assertion flood — fixed with realized flag, surface registry, GObject ref counting, onUnrealize callback
- [x] `surface.send_text` commands appearing but not executing — switched from `ghostty_surface_text` (bracketed paste) to `ghostty_surface_binding_action("text:...")` (direct PTY write)

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

### Priority 3: "Can I maintain state across sessions?" (Persistence)

Without this, every restart loses all context — workspaces, layouts, running processes.

- [ ] **Session save** — Auto-save workspace layout, titles, pane tree structure, working directories to `~/.config/cmux/session.json` on a timer (every 8s like macOS).

- [ ] **Session restore** — On launch, rebuild windows/workspaces/pane trees from saved state.

- [ ] **Ghostty config integration** — Read `~/.config/ghostty/config` for font, colors, theme. Currently we load it through Ghostty's own config system but don't extract values for the UI.

### Priority 4: "Can I stay aware of what's happening?" (Observability)

- [ ] **Shell integration scripts** — Bash and Zsh scripts that hook into the prompt to:
  - `report_pwd` — current working directory per terminal
  - `report_git_branch` — current git branch for sidebar display
  - Set `CMUX_*` environment variables

- [ ] **Sidebar richness** — The macOS sidebar shows git branch, PR info, status metadata, log entries, progress bars, and listening ports. For Linux, start with:
  - Git branch display (fed by shell integration)
  - Status metadata (key-value pairs via socket)
  - Log entries (arbitrary text via socket)
  - Progress bar (0-100% via socket)

- [ ] **Desktop notifications** — Via libnotify on Linux. Notify when commands finish, builds fail, etc.

- [ ] **Notification socket methods** — `notification.create`, `notification.list`, `notification.clear`

### Priority 5: "Can I organize complex workflows?" (Power Features)

- [ ] **Command palette** — Fuzzy search for all actions. On Linux, a GtkSearchEntry + GtkListBox popup.

- [ ] **Workspace colors** — Visual differentiation between workspaces.

- [ ] **Workspace pinning** — Pin important workspaces to the top of the sidebar.

- [ ] **Multi-window** — Multiple independent GTK windows, each with their own workspace set.

- [ ] **Pane break/join** — Move a pane to a new workspace, or pull a pane from another workspace.

- [ ] **Terminal find/search** — Search within terminal scrollback.

### Priority 6: "Feature parity with macOS" (Long Tail)

These are significant features from macOS that would be valuable but aren't blocking basic use:

- [ ] **Browser panel** — Embedded web browser (WebKitGTK on Linux). The macOS version has 80+ automation API methods. This is essentially a separate product.

- [ ] **Markdown panel** — Render local markdown files in a pane.

- [ ] **Claude Code integration** — Session tracking, sidebar status. The macOS version has wrapper scripts and hook commands.

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

As of 2026-03-10: The Linux port builds cleanly, runs on X11, renders terminals via Ghostty's OpenGL renderer, supports split panes and multiple workspaces with sidebar navigation, has a working socket API with 25 methods, and a CLI tool. Priority 1 (basic usability) and Priority 2 (agent essentials) are complete. An AI agent can now read terminal output, send commands and keystrokes, create/close splits, navigate workspaces, resize/swap panes, and discover its own terminal context via environment variables — all through the socket API.

The honest assessment: we're ~20-25% of the way to full macOS feature parity, but we're at ~80% of the way to "an AI agent could start dogfooding this as a development environment." Priority 3 (persistence) and Priority 4 (observability) are next.
