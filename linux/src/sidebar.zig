const std = @import("std");
const c = @import("c.zig");
const TabManager = @import("tab_manager.zig");
const Workspace = @import("workspace.zig");

const log = std.log.scoped(.sidebar);

const Sidebar = @This();

const Allocator = std.mem.Allocator;

/// Helper to cast any GTK widget subtype to *GtkWidget with proper alignment.
inline fn asWidget(ptr: anytype) *c.GtkWidget {
    return @ptrCast(@alignCast(ptr));
}

/// Callback type for when the user selects a workspace in the sidebar.
pub const SelectCallback = *const fn (index: usize, userdata: ?*anyopaque) void;

/// The outer container (vertical box: header + scrolled list).
container: *c.GtkBox,

/// The scrolled window containing the list box.
scrolled: *c.GtkScrolledWindow,

/// The GtkListBox holding workspace rows.
list_box: *c.GtkListBox,

/// Reference to the tab manager for reading workspace data.
tab_manager: *TabManager,

/// Workspace selection callback.
on_select: ?SelectCallback = null,
on_select_userdata: ?*anyopaque = null,

/// Whether we're programmatically updating selection (to avoid re-entrant callbacks).
updating: bool = false,

alloc: Allocator,

pub fn create(alloc: Allocator, tab_manager: *TabManager) !*Sidebar {
    const self = try alloc.create(Sidebar);

    // Create the sidebar container (vertical box)
    const container: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0));
    c.gtk_widget_set_size_request(asWidget(container), 200, -1);
    c.gtk_widget_add_css_class(asWidget(container), "sidebar");

    // Create header label
    const header_box: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0));
    c.gtk_widget_set_margin_start(asWidget(header_box), 12);
    c.gtk_widget_set_margin_end(asWidget(header_box), 12);
    c.gtk_widget_set_margin_top(asWidget(header_box), 8);
    c.gtk_widget_set_margin_bottom(asWidget(header_box), 8);

    const header_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new("Workspaces")));
    c.gtk_label_set_xalign(header_label, 0.0);
    c.gtk_widget_set_hexpand(asWidget(header_label), 1);
    c.gtk_widget_add_css_class(asWidget(header_label), "heading");
    c.gtk_box_append(header_box, asWidget(header_label));

    c.gtk_box_append(container, asWidget(header_box));

    // Add a separator
    const sep: *c.GtkSeparator = @ptrCast(@alignCast(c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL)));
    c.gtk_box_append(container, asWidget(sep));

    // Create the scrolled window for the list
    const scrolled: *c.GtkScrolledWindow = @ptrCast(@alignCast(c.gtk_scrolled_window_new()));
    c.gtk_scrolled_window_set_policy(scrolled, c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_vexpand(asWidget(scrolled), 1);

    // Create the list box
    const list_box: *c.GtkListBox = @ptrCast(@alignCast(c.gtk_list_box_new()));
    c.gtk_list_box_set_selection_mode(list_box, c.GTK_SELECTION_SINGLE);

    c.gtk_scrolled_window_set_child(scrolled, asWidget(list_box));
    c.gtk_box_append(container, asWidget(scrolled));

    self.* = .{
        .container = container,
        .scrolled = scrolled,
        .list_box = list_box,
        .tab_manager = tab_manager,
        .alloc = alloc,
    };

    // Connect row-selected signal
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(list_box)),
        "row-selected",
        @as(c.GCallback, @ptrCast(&onRowSelected)),
        @ptrCast(self),
        null,
        0,
    );

    // Build initial rows
    self.rebuild();

    return self;
}

pub fn deinit(self: *Sidebar) void {
    self.alloc.destroy(self);
}

/// Get the sidebar's top-level widget for embedding in a container.
pub fn widget(self: *Sidebar) *c.GtkWidget {
    return asWidget(self.container);
}

/// Set the workspace selection callback.
pub fn setSelectCallback(self: *Sidebar, cb: SelectCallback, userdata: ?*anyopaque) void {
    self.on_select = cb;
    self.on_select_userdata = userdata;
}

/// Rebuild the sidebar list from the tab manager's workspace list.
/// Call this after workspace create/close/reorder operations.
pub fn rebuild(self: *Sidebar) void {
    // Remove all existing rows
    while (true) {
        const row = c.gtk_list_box_get_row_at_index(self.list_box, 0);
        if (row == null) break;
        c.gtk_list_box_remove(self.list_box, asWidget(row));
    }

    // Add a row for each workspace
    for (self.tab_manager.workspaces.items) |ws| {
        const row_widget = createWorkspaceRow(ws);
        c.gtk_list_box_append(self.list_box, row_widget);
    }

    // Select the current workspace's row
    self.syncSelection();
}

/// Update the selection highlight to match the tab manager's selected workspace.
pub fn syncSelection(self: *Sidebar) void {
    self.updating = true;
    defer self.updating = false;

    if (self.tab_manager.selected_index) |idx| {
        const row = c.gtk_list_box_get_row_at_index(self.list_box, @intCast(idx));
        c.gtk_list_box_select_row(self.list_box, row);
    } else {
        c.gtk_list_box_select_row(self.list_box, null);
    }
}

/// Update a single workspace row's content (e.g., after rename or git branch change).
pub fn updateRow(self: *Sidebar, index: usize) void {
    if (index >= self.tab_manager.workspaces.items.len) return;

    const ws = self.tab_manager.workspaces.items[index];
    const row = c.gtk_list_box_get_row_at_index(self.list_box, @intCast(index));
    if (row == null) return;

    // Replace the row's child with updated content
    const content = createRowContentBox(ws);
    c.gtk_list_box_row_set_child(row, asWidget(content));
}

// ------------------------------------------------------------------
// Row creation
// ------------------------------------------------------------------

fn createWorkspaceRow(ws: *const Workspace) *c.GtkWidget {
    const row: *c.GtkListBoxRow = @ptrCast(@alignCast(c.gtk_list_box_row_new()));
    const content = createRowContentBox(ws);
    c.gtk_list_box_row_set_child(row, asWidget(content));
    return asWidget(row);
}

fn createRowContentBox(ws: *const Workspace) *c.GtkBox {
    // Each row is a vertical box with:
    // - Title label
    // - Subtitle label (git branch or pane count)
    const vbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2));
    c.gtk_widget_set_margin_start(asWidget(vbox), 12);
    c.gtk_widget_set_margin_end(asWidget(vbox), 12);
    c.gtk_widget_set_margin_top(asWidget(vbox), 6);
    c.gtk_widget_set_margin_bottom(asWidget(vbox), 6);

    // Title - must be null terminated
    const title = ws.getTitle();
    var title_z: [257]u8 = undefined;
    const title_len = @min(title.len, 256);
    @memcpy(title_z[0..title_len], title[0..title_len]);
    title_z[title_len] = 0;

    const title_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(&title_z)));
    c.gtk_label_set_xalign(title_label, 0.0);
    c.gtk_label_set_ellipsize(title_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_set_hexpand(asWidget(title_label), 1);
    c.gtk_box_append(vbox, asWidget(title_label));

    // Subtitle: git branch or pane count
    var subtitle_buf: [128]u8 = undefined;
    const pane_count = ws.paneCount();
    const subtitle_slice = if (ws.getGitBranch()) |branch|
        std.fmt.bufPrint(&subtitle_buf, "{s}", .{branch}) catch "..."
    else
        std.fmt.bufPrint(&subtitle_buf, "{d} pane{s}", .{
            pane_count,
            @as([]const u8, if (pane_count != 1) "s" else ""),
        }) catch "...";

    // Null terminate
    var sub_z: [129]u8 = undefined;
    const sub_len = @min(subtitle_slice.len, 128);
    @memcpy(sub_z[0..sub_len], subtitle_slice[0..sub_len]);
    sub_z[sub_len] = 0;

    const subtitle_label: *c.GtkLabel = @ptrCast(@alignCast(c.gtk_label_new(&sub_z)));
    c.gtk_label_set_xalign(subtitle_label, 0.0);
    c.gtk_label_set_ellipsize(subtitle_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(asWidget(subtitle_label), "dim-label");
    c.gtk_box_append(vbox, asWidget(subtitle_label));

    return vbox;
}

// ------------------------------------------------------------------
// Signal handlers
// ------------------------------------------------------------------

fn onRowSelected(
    _: *c.GtkListBox,
    row: ?*c.GtkListBoxRow,
    userdata: c.gpointer,
) callconv(.c) void {
    const self: *Sidebar = @ptrCast(@alignCast(userdata));

    // Ignore programmatic selection updates
    if (self.updating) return;

    if (row) |r| {
        const index: usize = @intCast(c.gtk_list_box_row_get_index(r));
        if (self.on_select) |cb| {
            cb(index, self.on_select_userdata);
        }
    }
}
