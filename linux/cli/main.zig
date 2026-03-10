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
    \\  workspace     Workspace management (list, create, current, select, close, rename)
    \\  surface       Surface management (list, current)
    \\  pane          Pane management (list)
    \\  window        Window management (list, current)
    \\  send          Send text to a surface
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
        } else {
            try stderr.writeAll("Unknown workspace subcommand. Use: list, create, current, select, close, rename\n");
        }
    } else if (std.mem.eql(u8, subcommand, "surface")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "surface.list", "{}", stdout, stderr);
        } else if (std.mem.eql(u8, sub, "current")) {
            try sendAndPrint(socket_path, "surface.current", "{}", stdout, stderr);
        } else {
            try stderr.writeAll("Unknown surface subcommand. Use: list, current\n");
        }
    } else if (std.mem.eql(u8, subcommand, "pane")) {
        const sub = args.next() orelse "list";
        if (std.mem.eql(u8, sub, "list")) {
            try sendAndPrint(socket_path, "pane.list", "{}", stdout, stderr);
        } else {
            try stderr.writeAll("Unknown pane subcommand. Use: list\n");
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
