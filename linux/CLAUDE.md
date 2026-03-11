# cmux Linux port — agent notes

## Using cmux-cli for development

When cmux is running, prefer using `cmux-cli` to interact with terminal sessions rather than the raw Bash tool. This gives you persistent sessions, parallel panes, and the ability to interact with running processes.

### Core workflow

```bash
# Send a command to the focused terminal pane
cmux-cli send "zig build 2>&1\n"

# Read the terminal output (viewport only)
cmux-cli surface read-text

# Read full scrollback buffer
cmux-cli surface read-text --scrollback

# Send keystrokes (ctrl-c, enter, tab, escape, arrow keys, etc.)
cmux-cli surface send-key ctrl-c
cmux-cli surface send-key enter

# Target a specific surface by ID
cmux-cli surface read-text 3 --scrollback
cmux-cli send "ls\n"   # sends to focused pane
```

### Parallel work with splits

```bash
# Create a split pane
cmux-cli surface split right    # left, right, up, down

# Close the focused pane
cmux-cli surface close

# Resize a pane (default amount 0.1)
cmux-cli pane resize <pane_id> right 0.2

# Swap two panes
cmux-cli pane swap <pane_a> <pane_b>
```

### Workspace management

```bash
cmux-cli workspace create "build"     # create a named workspace
cmux-cli workspace list               # list all workspaces
cmux-cli workspace select <id>        # switch workspace
cmux-cli workspace next               # cycle workspaces
```

### Observability — report status to the sidebar

```bash
cmux-cli workspace set-progress <id> 0.5 "Building..."
cmux-cli workspace set-status <id> task "compiling"
cmux-cli workspace add-log <id> "Build succeeded"
cmux-cli workspace report-git <id> main --dirty
```

### Discovery

```bash
cmux-cli identify        # show focused workspace/pane context
cmux-cli tree             # full hierarchy: windows → workspaces → panes
cmux-cli surface list     # list all surfaces with IDs
cmux-cli pane list        # list all panes
```

### Environment

Each terminal pane automatically gets these environment variables:
- `CMUX_SURFACE_ID` — this pane's surface ID
- `CMUX_WORKSPACE_ID` — this pane's workspace ID
- `CMUX_SOCKET_PATH` — path to the cmux socket

Socket path resolution: `CMUX_SOCKET` → `CMUX_SOCKET_PATH` → `/tmp/cmux.sock`

## Building

```bash
cd linux && zig build
```

This produces two binaries in `zig-out/bin/`:
- `cmux` — the GUI terminal (requires GTK4, libghostty, libnotify)
- `cmux-cli` — standalone socket client (libc only)

### Rebuilding libghostty

If the Ghostty submodule changes, rebuild via the setup script:

```bash
cd linux && ./setup.sh
```

## Architecture

- **Language:** Zig 0.14, `@cImport` for GTK4 and Ghostty C headers
- **UI:** GTK4 (GtkApplication, GtkGLArea, GtkPaned, GtkListBox)
- **Terminal:** Ghostty embedded apprt via `libghostty.so`
- **Socket:** Unix domain socket, newline-delimited JSON-RPC, thread-per-client
- **Source layout:** `src/` (GUI app), `cli/` (CLI tool), `src/socket/` (server + handlers)
