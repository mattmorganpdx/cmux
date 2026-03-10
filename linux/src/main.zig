const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig");
const Window = @import("window.zig");
const Server = @import("socket/server.zig");
const shortcuts = @import("shortcuts.zig");
const session = @import("session.zig");

const log = std.log.scoped(.main);

/// Global application state, initialized in activate callback.
pub var global_app: ?*App = null;
pub var global_window: ?*Window = null;
pub var global_server: ?*Server = null;

pub fn main() !void {
    const gtk_app = c.gtk_application_new(
        "com.cmuxterm.linux",
        c.G_APPLICATION_DEFAULT_FLAGS,
    ) orelse {
        log.err("Failed to create GtkApplication", .{});
        return error.GtkInitFailed;
    };
    defer c.g_object_unref(gtk_app);

    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gtk_app)),
        "activate",
        @as(c.GCallback, @ptrCast(&onActivate)),
        null,
        null,
        0,
    );

    const status = c.g_application_run(
        @as(*c.GApplication, @ptrCast(gtk_app)),
        @intCast(std.os.argv.len),
        @ptrCast(std.os.argv.ptr),
    );

    // Save session before cleanup
    if (global_window) |window| {
        const alloc = std.heap.c_allocator;
        if (session.captureSession(alloc, &window.tab_manager)) |snap| {
            defer session.freeSessionSnapshot(alloc, &snap);
            session.writeSessionFile(alloc, &snap) catch |err| {
                log.warn("Failed to save session on exit: {}", .{err});
            };
        } else |err| {
            log.warn("Failed to capture session on exit: {}", .{err});
        }
    }

    // Cleanup
    if (global_server) |server| {
        server.deinit();
        global_server = null;
    }

    if (global_app) |app| {
        app.deinit();
        global_app = null;
    }

    if (status != 0) {
        log.err("Application exited with status {}", .{status});
        return error.ApplicationFailed;
    }
}

fn onActivate(gtk_app: *c.GtkApplication, _: c.gpointer) callconv(.c) void {
    // Initialize the Ghostty backend on first activation
    if (global_app == null) {
        global_app = App.init() catch |err| {
            log.err("Failed to initialize Ghostty app: {}", .{err});
            return;
        };
    }

    // Create a new window (only on first activation)
    if (global_window != null) return;

    const app = global_app orelse return;

    // Try to restore session from disk
    const window = blk: {
        if (!session.isRestoreDisabled()) {
            if (session.loadSessionFile(std.heap.c_allocator)) |snap| {
                if (Window.createFromSession(gtk_app, app, &snap)) |w| {
                    log.info("Session restored ({d} workspaces)", .{snap.workspaces.len});
                    break :blk w;
                } else |err| {
                    log.warn("Session restore failed, starting fresh: {}", .{err});
                }
            } else |_| {}
        }
        break :blk Window.create(gtk_app, app) catch |err| {
            log.err("Failed to create window: {}", .{err});
            return;
        };
    };
    global_window = window;

    // Start autosave timer (every 8 seconds)
    _ = c.g_timeout_add_seconds(8, &session.onAutosave, @as(c.gpointer, @ptrCast(window)));

    // Install keyboard shortcuts
    shortcuts.install(window);

    // Start the socket server
    if (global_server == null) {
        const server = Server.init(std.heap.c_allocator) catch |err| {
            log.warn("Failed to init socket server: {}", .{err});
            return;
        };
        // Wire the window into the server so handlers can access app state
        server.window = window;
        server.start() catch |err| {
            log.warn("Failed to start socket server: {}", .{err});
            server.deinit();
            return;
        };
        global_server = server;
    }
}
