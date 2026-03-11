const std = @import("std");
const posix = std.posix;
const net = std.net;

const usage_text =
    \\cmux - terminal multiplexer for AI agents
    \\
    \\Usage: cmux <command> [args...]
    \\
    \\Commands:
    \\  ping          Ping the cmux server
    \\  identify      Show current focus context
    \\  capabilities  List available API methods
    \\  tree          Show workspace/pane hierarchy
    \\  workspace     Workspace management (list, create, current, select, close, rename,
    \\                  report-git, set-status, clear-status, add-log, clear-log, set-progress, set-pinned, set-color)
    \\  surface       Surface management (list, current, search, read-text, send-key, split, close)
    \\  pane          Pane management (list, break, join, resize, swap)
    \\  window        Window management (list, current)
    \\  send          Send text to a surface
    \\  notification  Notification management (create, list, clear)
    \\  palette       Command palette (list, execute)
    \\
    \\Environment:
    \\  CMUX_SOCKET       Socket path override
    \\  CMUX_SOCKET_PATH  Socket path override (fallback)
    \\
;

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    var args = std.process.args();
    _ = args.skip(); // skip program name

    const subcommand = args.next() orelse {
        try stdout.writeAll(usage_text);
        return;
    };

    // Determine socket path
    const socket_path = posix.getenv("CMUX_SOCKET") orelse
        posix.getenv("CMUX_SOCKET_PATH") orelse
        "/tmp/cmux.sock";

    // Dispatch subcommand
    if (std.mem.eql(u8, subcommand, "ping")) {
        try sendAndPrint(socket_path, "system.ping", "{}", stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "identify")) {
        try sendAndPrint(socket_path, "system.identify", "{}", stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "capabilities")) {
        try sendAndPrint(socket_path, "system.capabilities", "{}", stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "tree")) {
        try sendAndPrint(socket_path, "system.tree", "{}", stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "workspace")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "workspace.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "create")) {
            // Optional: cmux workspace create "My Title"
            const title = args.next();
            if (title) |t| {
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"title\":\"{s}\"}}", .{t}) catch {
                    try stderr.writeAll("Title too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.create", params, stdout, stderr);
            } else {
                try sendAndPrint(socket_path, "workspace.create", "{}", stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "current")) {
            try sendAndPrint(socket_path, "workspace.current", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "select")) {
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace select <id>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
                try stderr.writeAll("Invalid id\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.select", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "close")) {
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace close <id>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
                try stderr.writeAll("Invalid id\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.close", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "rename")) {
            const new_title = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace rename <title>\n");
                return;
            };
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"title\":\"{s}\"}}", .{new_title}) catch {
                try stderr.writeAll("Title too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.rename", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "report-git")) {
            // cmux workspace report-git <id> <branch> [--dirty]
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace report-git <id> <branch> [--dirty]\n");
                return;
            };
            const branch = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace report-git <id> <branch> [--dirty]\n");
                return;
            };
            var dirty = false;
            if (args.next()) |flag| {
                if (std.mem.eql(u8, flag, "--dirty")) dirty = true;
            }
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"branch\":\"{s}\",\"dirty\":{s}}}", .{
                id_str,
                branch,
                if (dirty) "true" else "false",
            }) catch {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.report_git", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "set-status")) {
            // cmux workspace set-status <id> <key> <value>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace set-status <id> <key> <value>\n");
                return;
            };
            const key = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace set-status <id> <key> <value>\n");
                return;
            };
            const value = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace set-status <id> <key> <value>\n");
                return;
            };
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"key\":\"{s}\",\"value\":\"{s}\"}}", .{ id_str, key, value }) catch {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.set_status", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "clear-status")) {
            // cmux workspace clear-status <id> [key]
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace clear-status <id> [key]\n");
                return;
            };
            if (args.next()) |key| {
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"key\":\"{s}\"}}", .{ id_str, key }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.clear_status", params, stdout, stderr);
            } else {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.clear_status", params, stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "add-log")) {
            // cmux workspace add-log <id> <text>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace add-log <id> <text>\n");
                return;
            };
            const text = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace add-log <id> <text>\n");
                return;
            };
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"text\":\"{s}\"}}", .{ id_str, text }) catch {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.add_log", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "clear-log")) {
            // cmux workspace clear-log <id>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace clear-log <id>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.clear_log", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "set-progress")) {
            // cmux workspace set-progress <id> <fraction> [label]
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace set-progress <id> <fraction> [label]\n");
                return;
            };
            const fraction = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace set-progress <id> <fraction> [label]\n");
                return;
            };
            if (args.next()) |label| {
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"fraction\":{s},\"label\":\"{s}\"}}", .{ id_str, fraction, label }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.set_progress", params, stdout, stderr);
            } else {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"fraction\":{s}}}", .{ id_str, fraction }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "workspace.set_progress", params, stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "set-pinned")) {
            // cmux workspace set-pinned <id> <true|false>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace set-pinned <id> <true|false>\n");
                return;
            };
            const val = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace set-pinned <id> <true|false>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"pinned\":{s}}}", .{ id_str, val }) catch {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "workspace.set_pinned", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "set-color")) {
            // cmux workspace set-color <id> <color|clear>
            const id_str = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace set-color <id> <red|blue|green|yellow|purple|orange|pink|cyan|clear>\n");
                return;
            };
            const color_val = args.next() orelse {
                try stderr.writeAll("Usage: cmux workspace set-color <id> <red|blue|green|yellow|purple|orange|pink|cyan|clear>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = if (std.mem.eql(u8, color_val, "clear"))
                std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"color\":\"\"}}", .{id_str}) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                }
            else
                std.fmt.bufPrint(&params_buf, "{{\"id\":{s},\"color\":\"{s}\"}}", .{ id_str, color_val }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
            try sendAndPrint(socket_path, "workspace.set_color", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "next")) {
            try sendAndPrint(socket_path, "workspace.next", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "previous") or std.mem.eql(u8, sub, "prev")) {
            try sendAndPrint(socket_path, "workspace.previous", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "last")) {
            try sendAndPrint(socket_path, "workspace.last", "{}", stdout, stderr);
        } else {
            try stderr.writeAll("Unknown workspace subcommand. Use: list, create, current, select, close, rename,\n  report-git, set-status, clear-status, add-log, clear-log, set-progress, set-pinned, set-color, next, previous, last\n");
        }
    } else if (std.mem.eql(u8, subcommand, "surface")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "surface.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "current")) {
            try sendAndPrint(socket_path, "surface.current", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "search")) {
            const search_text = args.next() orelse {
                try stderr.writeAll("Usage: cmux surface search <text>\n");
                return;
            };
            var params_buf: [4096]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"text\":\"{s}\"}}", .{search_text}) catch {
                try stderr.writeAll("Text too long\n");
                return;
            };
            try sendAndPrint(socket_path, "surface.search", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "read-text") or std.mem.eql(u8, sub, "read")) {
            // cmux surface read-text [surface_id] [--scrollback]
            var surface_id: ?[]const u8 = null;
            var scrollback = false;
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--scrollback")) {
                    scrollback = true;
                } else {
                    surface_id = arg;
                }
            }
            var params_buf: [256]u8 = undefined;
            const params = if (surface_id) |sid|
                if (scrollback)
                    std.fmt.bufPrint(&params_buf, "{{\"surface_id\":{s},\"scrollback\":true}}", .{sid}) catch {
                        try stderr.writeAll("Params too long\n");
                        return;
                    }
                else
                    std.fmt.bufPrint(&params_buf, "{{\"surface_id\":{s}}}", .{sid}) catch {
                        try stderr.writeAll("Params too long\n");
                        return;
                    }
            else if (scrollback)
                "{\"scrollback\":true}"
            else
                "{}";
            try sendAndPrint(socket_path, "surface.read_text", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "send-key")) {
            // cmux surface send-key <key> [surface_id]
            const key = args.next() orelse {
                try stderr.writeAll("Usage: cmux surface send-key <key> [surface_id]\n");
                return;
            };
            if (args.next()) |sid| {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"key\":\"{s}\",\"surface_id\":{s}}}", .{ key, sid }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "surface.send_key", params, stdout, stderr);
            } else {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"key\":\"{s}\"}}", .{key}) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "surface.send_key", params, stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "split")) {
            // cmux surface split <direction>
            const direction = args.next() orelse {
                try stderr.writeAll("Usage: cmux surface split <left|right|up|down>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"direction\":\"{s}\"}}", .{direction}) catch {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "surface.split", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "close")) {
            // cmux surface close
            try sendAndPrint(socket_path, "surface.close", "{}", stdout, stderr);
        } else {
            try stderr.writeAll("Unknown surface subcommand. Use: list, current, search, read-text, send-key, split, close\n");
        }
    } else if (std.mem.eql(u8, subcommand, "pane")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "pane.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "break")) {
            const pane_id = args.next() orelse {
                try stderr.writeAll("Usage: cmux pane break <pane_id>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"pane_id\":{s}}}", .{pane_id}) catch {
                try stderr.writeAll("Invalid pane_id\n");
                return;
            };
            try sendAndPrint(socket_path, "pane.break", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "join")) {
            const pane_id = args.next() orelse {
                try stderr.writeAll("Usage: cmux pane join <pane_id> <workspace_id>\n");
                return;
            };
            const workspace_id = args.next() orelse {
                try stderr.writeAll("Usage: cmux pane join <pane_id> <workspace_id>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"pane_id\":{s},\"workspace_id\":{s}}}", .{ pane_id, workspace_id }) catch {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "pane.join", params, stdout, stderr);
        } else if (std.mem.eql(u8, sub, "resize")) {
            // cmux pane resize <pane_id> <direction> [amount]
            const pane_id = args.next() orelse {
                try stderr.writeAll("Usage: cmux pane resize <pane_id> <left|right|up|down> [amount]\n");
                return;
            };
            const direction = args.next() orelse {
                try stderr.writeAll("Usage: cmux pane resize <pane_id> <left|right|up|down> [amount]\n");
                return;
            };
            if (args.next()) |amount| {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"pane_id\":{s},\"direction\":\"{s}\",\"amount\":{s}}}", .{ pane_id, direction, amount }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "pane.resize", params, stdout, stderr);
            } else {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"pane_id\":{s},\"direction\":\"{s}\"}}", .{ pane_id, direction }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "pane.resize", params, stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "swap")) {
            // cmux pane swap <pane_a> <pane_b>
            const pane_a = args.next() orelse {
                try stderr.writeAll("Usage: cmux pane swap <pane_a> <pane_b>\n");
                return;
            };
            const pane_b = args.next() orelse {
                try stderr.writeAll("Usage: cmux pane swap <pane_a> <pane_b>\n");
                return;
            };
            var params_buf: [256]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"pane_a\":{s},\"pane_b\":{s}}}", .{ pane_a, pane_b }) catch {
                try stderr.writeAll("Params too long\n");
                return;
            };
            try sendAndPrint(socket_path, "pane.swap", params, stdout, stderr);
        } else {
            try stderr.writeAll("Unknown pane subcommand. Use: list, break, join, resize, swap\n");
        }
    } else if (std.mem.eql(u8, subcommand, "send")) {
        const text = args.next() orelse {
            try stderr.writeAll("Usage: cmux send <text>\n");
            return;
        };
        // Build params JSON with escaped text
        var params_buf: [4096]u8 = undefined;
        const params = std.fmt.bufPrint(&params_buf, "{{\"text\":\"{s}\"}}", .{text}) catch {
            try stderr.writeAll("Text too long\n");
            return;
        };
        try sendAndPrint(socket_path, "surface.send_text", params, stdout, stderr);
    } else if (std.mem.eql(u8, subcommand, "window")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "window.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "current")) {
            try sendAndPrint(socket_path, "window.current", "{}", stdout, stderr);
        } else {
            try stderr.writeAll("Unknown window subcommand. Use: list, current\n");
        }
    } else if (std.mem.eql(u8, subcommand, "notification") or std.mem.eql(u8, subcommand, "notify")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "notification.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "create")) {
            const title = args.next() orelse {
                try stderr.writeAll("Usage: cmux notification create <title> [body]\n");
                return;
            };
            if (args.next()) |body| {
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"title\":\"{s}\",\"body\":\"{s}\"}}", .{ title, body }) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "notification.create", params, stdout, stderr);
            } else {
                var params_buf: [4096]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"title\":\"{s}\"}}", .{title}) catch {
                    try stderr.writeAll("Params too long\n");
                    return;
                };
                try sendAndPrint(socket_path, "notification.create", params, stdout, stderr);
            }
        } else if (std.mem.eql(u8, sub, "clear")) {
            if (args.next()) |id_str| {
                var params_buf: [256]u8 = undefined;
                const params = std.fmt.bufPrint(&params_buf, "{{\"id\":{s}}}", .{id_str}) catch {
                    try stderr.writeAll("Invalid id\n");
                    return;
                };
                try sendAndPrint(socket_path, "notification.clear", params, stdout, stderr);
            } else {
                try sendAndPrint(socket_path, "notification.clear", "{}", stdout, stderr);
            }
        } else {
            try stderr.writeAll("Unknown notification subcommand. Use: create, list, clear\n");
        }
    } else if (std.mem.eql(u8, subcommand, "palette")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "command_palette.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "execute") or std.mem.eql(u8, sub, "exec")) {
            const action_name = args.next() orelse {
                try stderr.writeAll("Usage: cmux palette execute <action-name>\n");
                return;
            };
            var params_buf: [512]u8 = undefined;
            const params = std.fmt.bufPrint(&params_buf, "{{\"action\":\"{s}\"}}", .{action_name}) catch {
                try stderr.writeAll("Action name too long\n");
                return;
            };
            try sendAndPrint(socket_path, "command_palette.execute", params, stdout, stderr);
        } else {
            try stderr.writeAll("Unknown palette subcommand. Use: list, execute\n");
        }
    } else {
        try stderr.writeAll("Unknown command: ");
        try stderr.writeAll(subcommand);
        try stderr.writeAll("\nRun 'cmux' for usage.\n");
    }
}

var next_req_id: i64 = 1;

fn sendAndPrint(socket_path: []const u8, method: []const u8, params: []const u8, stdout: std.fs.File, stderr: std.fs.File) !void {
    // Connect to socket
    const addr = net.Address.initUnix(socket_path) catch {
        try stderr.writeAll("Failed to create socket address\n");
        return;
    };
    const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0) catch {
        try stderr.writeAll("Failed to create socket\n");
        return;
    };
    defer posix.close(fd);

    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch {
        try stderr.writeAll("Failed to connect to cmux (is it running?)\n");
        try stderr.writeAll("Socket path: ");
        try stderr.writeAll(socket_path);
        try stderr.writeAll("\n");
        return;
    };

    const stream = net.Stream{ .handle = fd };

    // Build and send request
    const id = next_req_id;
    next_req_id += 1;

    var req_buf: [8192]u8 = undefined;
    const req_line = std.fmt.bufPrint(&req_buf,
        \\{{"id":{d},"method":"{s}","params":{s}}}
    , .{ id, method, params }) catch {
        try stderr.writeAll("Request too large\n");
        return;
    };

    stream.writeAll(req_line) catch {
        try stderr.writeAll("Failed to send request\n");
        return;
    };
    stream.writeAll("\n") catch {};

    // Read response
    var resp_buf: [65536]u8 = undefined;
    const n = stream.read(&resp_buf) catch {
        try stderr.writeAll("Failed to read response\n");
        return;
    };

    if (n == 0) {
        try stderr.writeAll("Empty response from server\n");
        return;
    }

    // Trim trailing newline
    var response = resp_buf[0..n];
    while (response.len > 0 and (response[response.len - 1] == '\n' or response[response.len - 1] == '\r')) {
        response = response[0 .. response.len - 1];
    }

    try stdout.writeAll(response);
    try stdout.writeAll("\n");
}
