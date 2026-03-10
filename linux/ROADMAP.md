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

### Priority 1: "Can I use this terminal at all?" (Basic Usability)

These are blockers for anyone — human or AI — trying to use cmux as a daily terminal.

- [ ] **Clipboard read (paste)** — Currently a no-op. I can copy FROM the terminal but can't paste INTO it. For an agent, `send_text` is the primary input path, but clipboard paste is essential for human users.

- [ ] **Ghostty action callbacks** — Only `RENDER` is handled. At minimum:
  - `set_title` — so workspace/pane titles reflect what's running (shell prompt, `vim`, etc.)
  - `close_surface` — so Ghostty-initiated closes (e.g., `exit` in shell) actually remove the pane
  - `new_split` — so Ghostty's own split key bindings work
  - `cell_size` — needed for proper resize behavior

- [ ] **Working directory per terminal** — The field exists but is ignored. New splits and workspaces should inherit the parent's cwd.

- [ ] **Socket `workspace.select` GTK widget switching** — Right now selecting a workspace via socket/CLI updates the data model but doesn't actually switch the visible GTK widgets. This means I can't drive the UI from the socket.

- [ ] **Split divider positioning** — Currently hardcoded to `0.5 * 480px`. Should read actual GTK allocation so splits look correct at any window size.

### Priority 2: "Can I drive this programmatically?" (Agent Essentials)

These are what I specifically need to use cmux as my own development environment.

- [ ] **`surface.read_text`** — Read the current terminal content back. Without this, I can send commands but can't see the output through the socket. This is THE critical loop-closing feature for agent use.

- [ ] **`surface.split` via socket** — Create splits programmatically. Currently I'd need keyboard shortcuts.

- [ ] **`surface.close` via socket** — Close panes programmatically.

- [ ] **`surface.send_key` via socket** — Send individual keystrokes (Ctrl+C, Ctrl+D, arrow keys, etc.) — essential for interacting with interactive programs.

- [ ] **`pane.resize` via socket** — The data model supports it, just needs a socket handler.

- [ ] **`pane.swap` via socket** — Same — data model ready, needs handler.

- [ ] **`workspace.next` / `workspace.previous` / `workspace.last` via socket** — Quick navigation without knowing workspace IDs.

- [ ] **Environment variables per surface** — `CMUX_SOCKET_PATH`, `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID` so scripts inside terminals know where they are.

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

As of 2026-03-09: The Linux port builds cleanly, runs on X11, renders terminals via Ghostty's OpenGL renderer, supports split panes and multiple workspaces with sidebar navigation, has a working socket API with 16 methods, and a CLI tool. Two significant bugs were fixed this session (GTK-CRITICAL render errors and send_text not executing commands). All code is committed on the `matt/port-to-linux` branch.

The honest assessment: we're ~15-20% of the way to full macOS feature parity, but we're at maybe ~60% of the way to "an AI agent could start dogfooding this as a development environment" — which is the more interesting milestone.
