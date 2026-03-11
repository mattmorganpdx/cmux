const std = @import("std");
const c = @import("c.zig");
const Window = @import("window.zig");
const PaneTree = @import("pane_tree.zig");

const log = std.log.scoped(.command_palette);

const CommandPalette = @This();

const Allocator = std.mem.Allocator;

/// Helper to cast any GTK widget subtype to *GtkWidget with proper alignment.
inline fn asWidget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}

/// A command palette action.
pub const Action = struct {
    name: []const u8,
    description: []const u8,
    callback: *const fn (*Window) void,
};

/// Registered actions.
const actions = [_]Action{
    .{ .name = "New Workspace", .description = "Create a new workspace", .callback = &doNewWorkspace },
    .{ .name = "Split Right", .description = "Split the focused pane to the right", .callback = &doSplitRight },
    .{ .name = "Split Down", .description = "Split the focused pane downward", .callback = &doSplitDown },
    .{ .name = "Close Pane", .description = "Close the focused pane", .callback = &doClosePane },
    .{ .name = "Next Workspace", .description = "Switch to the next workspace", .callback = &doNextWorkspace },
    .{ .name = "Previous Workspace", .description = "Switch to the previous workspace", .callback = &doPreviousWorkspace },
    .{ .name = "Toggle Sidebar", .description = "Show or hide the sidebar", .callback = &doToggleSidebar },
    .{ .name = "Navigate Left", .description = "Move focus to the pane on the left", .callback = &doNavLeft },
    .{ .name = "Navigate Right", .description = "Move focus to the pane on the right", .callback = &doNavRight },
    .{ .name = "Navigate Up", .description = "Move focus to the pane above", .callback = &doNavUp },
    .{ .name = "Navigate Down", .description = "Move focus to the pane below", .callback = &doNavDown },
};

// Action callbacks
fn doNewWorkspace(w: *Window) void {
    w.createWorkspace() catch |err| log.warn("Failed to create workspace: {}", .{err});
}
fn doSplitRight(w: *Window) void {
    w.splitFocused(.right) catch |err| log.warn("Failed to split right: {}", .{err});
}
fn doSplitDown(w: *Window) void {
    w.splitFocused(.down) catch |err| log.warn("Failed to split down: {}", .{err});
}
fn doClosePane(w: *Window) void {
    w.closeFocused() catch |err| log.warn("Failed to close pane: {}", .{err});
}
fn doNextWorkspace(w: *Window) void {
    w.nextWorkspace();
}
fn doPreviousWorkspace(w: *Window) void {
    w.previousWorkspace();
}
fn doToggleSidebar(w: *Window) void {
    w.toggleSidebar();
}
fn doNavLeft(w: *Window) void {
    w.navigateFocus(.left);
}
fn doNavRight(w: *Window) void {
    w.navigateFocus(.right);
}
fn doNavUp(w: *Window) void {
    w.navigateFocus(.up);
}
fn doNavDown(w: *Window) void {
    w.navigateFocus(.down);
}

/// The outer container for the palette overlay widget.
container: *c.GtkBox,

/// The search entry.
search_entry: *c.GtkSearchEntry,

/// The list box showing filtered results.
list_box: *c.GtkListBox,

/// Whether the palette is currently visible.
visible: bool = false,

/// Reference to the window.
window: *Window,

/// Allocator.
alloc: Allocator,

pub fn create(alloc: Allocator, window: *Window) !*CommandPalette {
    const self = try alloc.create(CommandPalette);

    // Outer container: a vertical box with the command-palette CSS class
    const container: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4));
    c.gtk_widget_add_css_class(asWidget(container), "command-palette");
    c.gtk_widget_set_size_request(asWidget(container), 400, -1);

    // Position at the top center of the overlay
    c.gtk_widget_set_halign(asWidget(container), c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_valign(asWidget(container), c.GTK_ALIGN_START);

    // Margins from top
    c.gtk_widget_set_margin_top(asWidget(container), 40);

    // Search entry
    const search_entry: *c.GtkSearchEntry = @ptrCast(@alignCast(c.gtk_search_entry_new()));
    c.gtk_box_append(container, asWidget(search_entry));

    // Results list box
    const list_box: *c.GtkListBox = @ptrCast(@alignCast(c.gtk_list_box_new()));
    c.gtk_list_box_set_selection_mode(list_box, c.GTK_SELECTION_SINGLE);

    // Scrolled window for results
    const scrolled: *c.GtkScrolledWindow = @ptrCast(@alignCast(c.gtk_scrolled_window_new()));
    c.gtk_scrolled_window_set_policy(scrolled, c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_size_request(asWidget(scrolled), -1, 300);
    c.gtk_scrolled_window_set_child(scrolled, asWidget(list_box));
    c.gtk_box_append(container, asWidget(scrolled));

    // Start hidden
    c.gtk_widget_set_visible(asWidget(container), 0);

    self.* = .{
        .container = container,
        .search_entry = search_entry,
        .list_box = list_box,
        .window = window,
        .alloc = alloc,
    };

    // Connect search-changed signal
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(search_entry)),
        "search-changed",
        @as(c.GCallback, @ptrCast(&onSearchChanged)),
        @ptrCast(self),
        null,
        0,
    );

    // Connect key-pressed on search entry for Enter/Escape
    const key_controller = c.gtk_event_controller_key_new();
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(key_controller)),
        "key-pressed",
        @as(c.GCallback, @ptrCast(&onKeyPressed)),
        @ptrCast(self),
        null,
        0,
    );
    c.gtk_widget_add_controller(asWidget(search_entry), key_controller);

    // Populate with all actions initially
    self.populateResults("");

    return self;
}

pub fn deinit(self: *CommandPalette) void {
    self.alloc.destroy(self);
}

/// Get the palette's widget for embedding in the overlay.
pub fn widget(self: *CommandPalette) *c.GtkWidget {
    return asWidget(self.container);
}

/// Show the palette.
pub fn show(self: *CommandPalette) void {
    self.visible = true;
    c.gtk_widget_set_visible(asWidget(self.container), 1);

    // Clear the search entry and populate with all actions
    c.gtk_editable_set_text(@ptrCast(self.search_entry), "");
    self.populateResults("");

    // Focus the search entry
    _ = c.gtk_widget_grab_focus(asWidget(self.search_entry));
}

/// Hide the palette.
pub fn hide(self: *CommandPalette) void {
    self.visible = false;
    c.gtk_widget_set_visible(asWidget(self.container), 0);
}

/// Toggle visibility.
pub fn toggle(self: *CommandPalette) void {
    if (self.visible) {
        self.hide();
    } else {
        self.show();
    }
}

/// Execute an action by name (fuzzy match). Used by socket handler.
pub fn executeByName(self: *CommandPalette, name: []const u8) bool {
    // Exact match first
    for (actions) |action| {
        if (std.ascii.eqlIgnoreCase(action.name, name)) {
            action.callback(self.window);
            return true;
        }
    }
    // Fuzzy match: case-insensitive substring
    for (actions) |action| {
        if (containsIgnoreCase(action.name, name) or containsIgnoreCase(action.description, name)) {
            action.callback(self.window);
            return true;
        }
    }
    return false;
}

/// Get the list of all registered actions.
pub fn getActions() []const Action {
    return &actions;
}

// ------------------------------------------------------------------
// Internal
// ------------------------------------------------------------------

fn populateResults(self: *CommandPalette, query: []const u8) void {
    // Remove all existing rows
    while (true) {
        const row = c.gtk_list_box_get_row_at_index(self.list_box, 0);
        if (row == null) break;
        c.gtk_list_box_remove(self.list_box, asWidget(row));
    }

    // Add matching actions
    var count: usize = 0;
    for (actions) |action| {
        if (query.len == 0 or matchesQuery(action, query)) {
            appendActionRow(self.list_box, action);
            count += 1;
        }
    }

    // Select the first row
    if (count > 0) {
        const first_row = c.gtk_list_box_get_row_at_index(self.list_box, 0);
        c.gtk_list_box_select_row(self.list_box, first_row);
    }
}

fn matchesQuery(action: Action, query: []const u8) bool {
    return containsIgnoreCase(action.name, query) or containsIgnoreCase(action.description, query);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn appendActionRow(list_box: *c.GtkListBox, action: Action) void {
    const row: *c.GtkListBoxRow = @ptrCast(@alignCast(c.gtk_list_box_row_new()));

    const vbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2));
    c.gtk_widget_set_margin_start(asWidget(vbox), 8);
    c.gtk_widget_set_margin_end(asWidget(vbox), 8);
    c.gtk_widget_set_margin_top(asWidget(vbox), 4);
    c.gtk_widget_set_margin_bottom(asWidget(vbox), 4);

    // Name label
    var name_z: [128]u8 = undefined;
    const name_len = @min(action.name.len, name_z.len - 1);
    @memcpy(name_z[0..name_len], action.name[0..name_len]);
    name_z[name_len] = 0;
    const name_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(&name_z)));
    c.gtk_label_set_xalign(name_label, 0.0);
    c.gtk_box_append(vbox, asWidget(name_label));

    // Description label (dim)
    var desc_z: [256]u8 = undefined;
    const desc_len = @min(action.description.len, desc_z.len - 1);
    @memcpy(desc_z[0..desc_len], action.description[0..desc_len]);
    desc_z[desc_len] = 0;
    const desc_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(&desc_z)));
    c.gtk_label_set_xalign(desc_label, 0.0);
    c.gtk_widget_add_css_class(asWidget(desc_label), "dim-label");
    c.gtk_box_append(vbox, asWidget(desc_label));

    c.gtk_list_box_row_set_child(row, asWidget(vbox));
    c.gtk_list_box_append(list_box, asWidget(row));

    // Store the action index on the row
    const idx = getActionIndex(action.name);
    c.g_object_set_data(
        @as([*c]c.GObject, @ptrCast(row)),
        "action-idx",
        @ptrFromInt(idx),
    );
}

fn getActionIndex(name: []const u8) usize {
    for (actions, 0..) |a, i| {
        if (std.mem.eql(u8, a.name, name)) return i;
    }
    return 0;
}

fn executeSelectedAction(self: *CommandPalette) void {
    const selected_row = c.gtk_list_box_get_selected_row(self.list_box);
    if (selected_row == null) return;

    const idx = @intFromPtr(c.g_object_get_data(
        @as([*c]c.GObject, @ptrCast(selected_row.?)),
        "action-idx",
    ));

    if (idx < actions.len) {
        self.hide();
        actions[idx].callback(self.window);
    }
}

// ------------------------------------------------------------------
// Signal handlers
// ------------------------------------------------------------------

fn onSearchChanged(
    _: *c.GtkSearchEntry,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *CommandPalette = @ptrCast(@alignCast(userdata));
    const text_ptr = c.gtk_editable_get_text(@ptrCast(self.search_entry));
    if (text_ptr == null) return;

    // Read the C string into a Zig slice
    const text = std.mem.span(text_ptr.?);
    self.populateResults(text);
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c.guint,
    _: c.guint,
    _: c.GdkModifierType,
    userdata: c.gpointer,
) callconv(.c) c.gboolean {
    const self: *CommandPalette = @ptrCast(@alignCast(userdata));

    if (keyval == c.GDK_KEY_Escape) {
        self.hide();
        return 1;
    }

    if (keyval == c.GDK_KEY_Return) {
        self.executeSelectedAction();
        return 1;
    }

    // Arrow down: move selection in list box
    if (keyval == c.GDK_KEY_Down) {
        const selected = c.gtk_list_box_get_selected_row(self.list_box);
        if (selected) |row| {
            const idx = c.gtk_list_box_row_get_index(row);
            const next = c.gtk_list_box_get_row_at_index(self.list_box, idx + 1);
            if (next) |n| {
                c.gtk_list_box_select_row(self.list_box, n);
            }
        }
        return 1;
    }

    // Arrow up: move selection in list box
    if (keyval == c.GDK_KEY_Up) {
        const selected = c.gtk_list_box_get_selected_row(self.list_box);
        if (selected) |row| {
            const idx = c.gtk_list_box_row_get_index(row);
            if (idx > 0) {
                const prev = c.gtk_list_box_get_row_at_index(self.list_box, idx - 1);
                if (prev) |p| {
                    c.gtk_list_box_select_row(self.list_box, p);
                }
            }
        }
        return 1;
    }

    return 0;
}
