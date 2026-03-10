const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig");

const log = std.log.scoped(.terminal_widget);

const TerminalWidget = @This();

/// The GtkGLArea widget for rendering.
gl_area: *c.GtkGLArea,

/// The Ghostty surface handle.
surface: c.ghostty_surface_t,

/// Reference to the Ghostty app.
app: *App,

/// Whether the GtkGLArea has been realized and the surface created.
/// When false, queueRender is a no-op to avoid GTK assertions.
realized: bool = false,

/// Global registry mapping ghostty_surface_t → *TerminalWidget.
/// Used by the action callback to look up widgets without relying on
/// ghostty_surface_userdata pointer interpretation.
var surface_registry: std.AutoHashMapUnmanaged(usize, *TerminalWidget) = .empty;

/// Look up a TerminalWidget by its Ghostty surface handle.
pub fn fromSurface(surface: c.ghostty_surface_t) ?*TerminalWidget {
    if (surface == null) return null;
    return surface_registry.get(@intFromPtr(surface));
}

/// Create a new terminal widget backed by a GtkGLArea + Ghostty surface.
pub fn create(app: *App, working_directory: ?[*:0]const u8) !*TerminalWidget {
    const alloc = std.heap.c_allocator;

    // Create the GtkGLArea
    const gl_area: *c.GtkGLArea = @ptrCast(c.gtk_gl_area_new() orelse
        return error.GtkGLAreaFailed);

    // Request OpenGL 3.3 core profile (Ghostty's minimum)
    c.gtk_gl_area_set_required_version(gl_area, 3, 3);
    c.gtk_gl_area_set_has_depth_buffer(gl_area, 0);
    c.gtk_gl_area_set_has_stencil_buffer(gl_area, 0);
    c.gtk_gl_area_set_auto_render(gl_area, 0);

    // Make the widget expand to fill available space
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(gl_area)), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(gl_area)), 1);

    // Enable the widget to receive focus and input
    c.gtk_widget_set_focusable(@as(*c.GtkWidget, @ptrCast(gl_area)), 1);
    c.gtk_widget_set_can_focus(@as(*c.GtkWidget, @ptrCast(gl_area)), 1);

    // Hold our own GObject reference on the GtkGLArea to prevent
    // GTK from finalizing it while we still hold a pointer.
    _ = c.g_object_ref(@as(c.gpointer, @ptrCast(gl_area)));

    const self = try alloc.create(TerminalWidget);
    self.* = .{
        .gl_area = gl_area,
        .surface = null,
        .app = app,
    };

    // Connect signals
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gl_area)),
        "realize",
        @as(c.GCallback, @ptrCast(&onRealize)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gl_area)),
        "unrealize",
        @as(c.GCallback, @ptrCast(&onUnrealize)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gl_area)),
        "render",
        @as(c.GCallback, @ptrCast(&onRender)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(gl_area)),
        "resize",
        @as(c.GCallback, @ptrCast(&onResize)),
        @ptrCast(self),
        null,
        0,
    );

    // Set up keyboard input
    const key_controller = c.gtk_event_controller_key_new();
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(key_controller)),
        "key-pressed",
        @as(c.GCallback, @ptrCast(&onKeyPressed)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(key_controller)),
        "key-released",
        @as(c.GCallback, @ptrCast(&onKeyReleased)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(
        @as(*c.GtkWidget, @ptrCast(gl_area)),
        key_controller,
    );

    // Set up mouse/scroll input
    const click_gesture = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click_gesture), 0); // all buttons
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(click_gesture)),
        "pressed",
        @as(c.GCallback, @ptrCast(&onMousePressed)),
        @ptrCast(self),
        null,
        0,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(click_gesture)),
        "released",
        @as(c.GCallback, @ptrCast(&onMouseReleased)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(
        @as(*c.GtkWidget, @ptrCast(gl_area)),
        @ptrCast(click_gesture),
    );

    const scroll_controller = c.gtk_event_controller_scroll_new(
        c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES |
            c.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE,
    );
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(scroll_controller)),
        "scroll",
        @as(c.GCallback, @ptrCast(&onScroll)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(
        @as(*c.GtkWidget, @ptrCast(gl_area)),
        scroll_controller,
    );

    // Motion controller for mouse movement tracking
    const motion_controller = c.gtk_event_controller_motion_new();
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(motion_controller)),
        "motion",
        @as(c.GCallback, @ptrCast(&onMotion)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(
        @as(*c.GtkWidget, @ptrCast(gl_area)),
        motion_controller,
    );

    // Store the working directory for surface creation in onRealize
    // (GtkGLArea needs to be realized before we can create the GL context)
    _ = working_directory; // TODO: store and use in onRealize

    return self;
}

pub fn deinit(self: *TerminalWidget) void {
    self.realized = false;

    // Remove from registry before freeing the surface
    if (self.surface != null) {
        _ = surface_registry.remove(@intFromPtr(self.surface));
        c.ghostty_surface_free(self.surface);
        self.surface = null;
    }

    // Release our GObject reference on the GtkGLArea
    c.g_object_unref(@as(c.gpointer, @ptrCast(self.gl_area)));

    std.heap.c_allocator.destroy(self);
}

/// Get the underlying GtkWidget for embedding in containers.
pub fn widget(self: *TerminalWidget) *c.GtkWidget {
    return @ptrCast(self.gl_area);
}

/// Request a redraw of the terminal surface.
/// Only queues a render if the GtkGLArea has been realized and the
/// Ghostty surface is active. This prevents GTK_IS_GL_AREA assertions.
pub fn queueRender(self: *TerminalWidget) void {
    if (!self.realized) return;
    if (self.surface == null) return;
    c.gtk_gl_area_queue_render(self.gl_area);
}

// --- GTK signal callbacks ---

fn onRealize(gl_area: *c.GtkGLArea, userdata: c.gpointer) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));

    // Make the GL context current so Ghostty can initialize
    c.gtk_gl_area_make_current(gl_area);
    if (c.gtk_gl_area_get_error(gl_area)) |err| {
        log.err("GL context error on realize: {s}", .{err.*.message});
        return;
    }

    // Get the scale factor for HiDPI
    const gtk_widget: *c.GtkWidget = @ptrCast(gl_area);
    const scale: f64 = @floatFromInt(c.gtk_widget_get_scale_factor(gtk_widget));

    // Configure the Ghostty surface
    var surface_config = self.app.newSurfaceConfig();
    surface_config.platform_tag = c.GHOSTTY_PLATFORM_LINUX;
    surface_config.platform = .{ .gtk_linux = .{
        .gl_area = @ptrCast(gl_area),
    } };
    surface_config.scale_factor = scale;
    surface_config.userdata = @ptrCast(self);

    // Create the Ghostty surface
    self.surface = c.ghostty_surface_new(self.app.ghostty_app, &surface_config);
    if (self.surface == null) {
        log.err("Failed to create Ghostty surface", .{});
        return;
    }

    // Register in the global surface → widget map so the action callback
    // can look us up without relying on ghostty_surface_userdata.
    surface_registry.put(std.heap.c_allocator, @intFromPtr(self.surface), self) catch |err| {
        log.err("Failed to register surface in registry: {}", .{err});
    };

    // Mark as realized AFTER surface creation succeeds
    self.realized = true;

    log.info("Terminal surface created successfully", .{});

    // Queue initial render
    c.gtk_gl_area_queue_render(gl_area);
}

fn onUnrealize(_: *c.GtkGLArea, userdata: c.gpointer) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));

    // Mark as unrealized to prevent further queueRender calls
    self.realized = false;

    log.info("Terminal surface unrealized", .{});
}

fn onRender(
    gl_area: *c.GtkGLArea,
    _: *c.GdkGLContext,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    _ = gl_area;

    if (self.surface != null) {
        c.ghostty_surface_draw(self.surface);
    }

    return 1; // We handled the render
}

fn onResize(
    _: *c.GtkGLArea,
    width: c.gint,
    height: c.gint,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));

    if (self.surface != null) {
        c.ghostty_surface_set_size(self.surface, @intCast(width), @intCast(height));
    }
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    state: c.GdkModifierType,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    _ = keyval;
    if (self.surface == null) return 0;

    const mods = gtkModsToGhostty(state);
    const key_event = c.ghostty_input_key_s{
        .action = c.GHOSTTY_ACTION_PRESS,
        .mods = mods,
        .consumed_mods = c.GHOSTTY_MODS_NONE,
        .keycode = keycode,
        .text = null,
        .unshifted_codepoint = 0,
        .composing = false,
    };

    const consumed = c.ghostty_surface_key(self.surface, key_event);
    return if (consumed) 1 else 0;
}

fn onKeyReleased(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    state: c.GdkModifierType,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    _ = keyval;
    if (self.surface == null) return;

    const mods = gtkModsToGhostty(state);
    const key_event = c.ghostty_input_key_s{
        .action = c.GHOSTTY_ACTION_RELEASE,
        .mods = mods,
        .consumed_mods = c.GHOSTTY_MODS_NONE,
        .keycode = keycode,
        .text = null,
        .unshifted_codepoint = 0,
        .composing = false,
    };

    _ = c.ghostty_surface_key(self.surface, key_event);
}

fn onMousePressed(
    gesture: *c.GtkGestureClick,
    n_press: c.gint,
    x: c.gdouble,
    y: c.gdouble,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    _ = n_press;
    if (self.surface == null) return;

    const button = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    const ghostty_button = gtkButtonToGhostty(button);

    // ghostty_surface_mouse_button(surface, state, button, mods)
    _ = c.ghostty_surface_mouse_button(
        self.surface,
        c.GHOSTTY_MOUSE_PRESS,
        ghostty_button,
        c.GHOSTTY_MODS_NONE,
    );

    // Update cursor position
    c.ghostty_surface_mouse_pos(self.surface, x, y, c.GHOSTTY_MODS_NONE);
}

fn onMouseReleased(
    gesture: *c.GtkGestureClick,
    n_press: c.gint,
    x: c.gdouble,
    y: c.gdouble,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    _ = n_press;
    _ = x;
    _ = y;
    if (self.surface == null) return;

    const button = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
    const ghostty_button = gtkButtonToGhostty(button);

    _ = c.ghostty_surface_mouse_button(
        self.surface,
        c.GHOSTTY_MOUSE_RELEASE,
        ghostty_button,
        c.GHOSTTY_MODS_NONE,
    );
}

fn onScroll(
    _: *c.GtkEventControllerScroll,
    dx: c.gdouble,
    dy: c.gdouble,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    if (self.surface == null) return 0;

    // ghostty_surface_mouse_scroll(surface, dx, dy, scroll_mods)
    c.ghostty_surface_mouse_scroll(self.surface, dx, dy, 0);
    return 1;
}

fn onMotion(
    _: *c.GtkEventControllerMotion,
    x: c.gdouble,
    y: c.gdouble,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *TerminalWidget = @ptrCast(@alignCast(userdata));
    if (self.surface == null) return;

    c.ghostty_surface_mouse_pos(self.surface, x, y, c.GHOSTTY_MODS_NONE);
}

// --- Helper functions ---

fn gtkModsToGhostty(state: c.GdkModifierType) c.ghostty_input_mods_t {
    var mods: c.ghostty_input_mods_t = c.GHOSTTY_MODS_NONE;

    if (state & c.GDK_SHIFT_MASK != 0) mods |= c.GHOSTTY_MODS_SHIFT;
    if (state & c.GDK_CONTROL_MASK != 0) mods |= c.GHOSTTY_MODS_CTRL;
    if (state & c.GDK_ALT_MASK != 0) mods |= c.GHOSTTY_MODS_ALT;
    if (state & c.GDK_SUPER_MASK != 0) mods |= c.GHOSTTY_MODS_SUPER;

    return mods;
}

fn gtkButtonToGhostty(button: c.guint) c.ghostty_input_mouse_button_e {
    return switch (button) {
        1 => c.GHOSTTY_MOUSE_LEFT,
        2 => c.GHOSTTY_MOUSE_MIDDLE,
        3 => c.GHOSTTY_MOUSE_RIGHT,
        4 => c.GHOSTTY_MOUSE_FOUR,
        5 => c.GHOSTTY_MOUSE_FIVE,
        else => c.GHOSTTY_MOUSE_UNKNOWN,
    };
}
