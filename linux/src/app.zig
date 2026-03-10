const std = @import("std");
const c = @import("c.zig");
const Clipboard = @import("clipboard.zig");
const TerminalWidget = @import("terminal_widget.zig");

const log = std.log.scoped(.app);

const App = @This();

/// The opaque Ghostty app handle.
ghostty_app: c.ghostty_app_t,

/// The Ghostty config.
config: c.ghostty_config_t,

/// Initialize the Ghostty backend.
pub fn init() !*App {
    const alloc = std.heap.c_allocator;

    // Initialize Ghostty global state.
    // ghostty_init(argc, argv) - pass 0/null for embedded use.
    if (c.ghostty_init(0, null) != c.GHOSTTY_SUCCESS) {
        log.err("ghostty_init failed", .{});
        return error.GhosttyInitFailed;
    }

    // Load configuration
    const config = c.ghostty_config_new();
    c.ghostty_config_load_default_files(config);
    c.ghostty_config_load_recursive_files(config);
    c.ghostty_config_finalize(config);

    // Create the app with runtime callbacks.
    // Use zeroes to ensure all fields (including any padding) are initialized.
    var runtime_config: c.ghostty_runtime_config_s = std.mem.zeroes(c.ghostty_runtime_config_s);
    runtime_config.userdata = null;
    runtime_config.supports_selection_clipboard = true;
    runtime_config.wakeup_cb = &wakeupCallback;
    runtime_config.action_cb = &actionCallback;
    runtime_config.read_clipboard_cb = &Clipboard.readCallback;
    runtime_config.confirm_read_clipboard_cb = &Clipboard.confirmReadCallback;
    runtime_config.write_clipboard_cb = &Clipboard.writeCallback;
    runtime_config.close_surface_cb = &closeSurfaceCallback;

    const ghostty_app = c.ghostty_app_new(&runtime_config, config);
    if (ghostty_app == null) {
        log.err("ghostty_app_new failed", .{});
        c.ghostty_config_free(config);
        return error.GhosttyAppFailed;
    }

    const app = try alloc.create(App);
    app.* = .{
        .ghostty_app = ghostty_app,
        .config = config,
    };

    return app;
}

pub fn deinit(self: *App) void {
    if (self.ghostty_app != null) {
        c.ghostty_app_free(self.ghostty_app);
    }
    if (self.config != null) {
        c.ghostty_config_free(self.config);
    }
    std.heap.c_allocator.destroy(self);
}

/// Tick the Ghostty event loop. Called from the GTK main loop.
pub fn tick(self: *App) void {
    c.ghostty_app_tick(self.ghostty_app);
}

/// Create a new surface configuration inheriting from this app.
pub fn newSurfaceConfig(self: *App) c.ghostty_surface_config_s {
    _ = self;
    return c.ghostty_surface_config_new();
}

// --- Ghostty runtime callbacks ---

/// Called when Ghostty needs the event loop to tick.
/// We schedule this on the GTK main loop via g_idle_add.
fn wakeupCallback(_: ?*anyopaque) callconv(.c) void {
    _ = c.g_idle_add(&idleTickCallback, null);
}

fn idleTickCallback(_: c.gpointer) callconv(.c) c.gboolean {
    // Import the global app from main
    const main = @import("main.zig");
    if (main.global_app) |app| {
        app.tick();
    }
    return c.G_SOURCE_REMOVE;
}

/// Called when Ghostty wants to perform an action (e.g., set title, close, render).
fn actionCallback(
    app: ?*anyopaque,
    target: c.ghostty_target_s,
    action: c.ghostty_action_s,
) callconv(.c) bool {
    _ = app;

    switch (action.tag) {
        c.GHOSTTY_ACTION_RENDER => {
            // The renderer thread dispatches draw calls to the main thread
            // via the mailbox (must_draw_from_app_thread=true on Linux).
            // We need to queue a render on the GtkGLArea for the target surface.
            if (target.tag == c.GHOSTTY_TARGET_SURFACE) {
                const surface = target.target.surface;
                // Use the global surface registry to look up the TerminalWidget.
                // This avoids potential issues with ghostty_surface_userdata
                // pointer interpretation across C/Zig boundary.
                if (TerminalWidget.fromSurface(surface)) |tw| {
                    tw.queueRender();
                    return true;
                }
            }
            return false;
        },
        else => {
            // TODO: Handle other Ghostty actions (set_title, new_split, etc.)
            return false;
        },
    }
}

/// Called when Ghostty wants to close a surface.
fn closeSurfaceCallback(
    surface_userdata: ?*anyopaque,
    process_alive: bool,
) callconv(.c) void {
    _ = surface_userdata;
    _ = process_alive;
    // TODO: Close the terminal widget/pane containing this surface
}
