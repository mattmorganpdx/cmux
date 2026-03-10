const std = @import("std");
const c = @import("c.zig");
const App = @import("app.zig");
const TerminalWidget = @import("terminal_widget.zig");
const PaneTree = @import("pane_tree.zig");
const TabManager = @import("tab_manager.zig");
const Workspace = @import("workspace.zig");
const Sidebar = @import("sidebar.zig");
const session = @import("session.zig");

const log = std.log.scoped(.window);

const Window = @This();

const Allocator = std.mem.Allocator;

/// The GTK application window.
gtk_window: *c.GtkApplicationWindow,

/// The Ghostty app reference.
app: *App,

/// The workspace manager.
tab_manager: TabManager,

/// Map from PaneTree NodeId to the terminal widget for that pane.
pane_widgets: std.AutoHashMap(PaneTree.NodeId, *TerminalWidget),

/// Map from PaneTree NodeId to the GTK widget representing that node.
/// For pane nodes: the terminal's GtkWidget.
/// For split nodes: a GtkPaned widget.
node_widgets: std.AutoHashMap(PaneTree.NodeId, *c.GtkWidget),

/// The main content area where the current workspace's widget tree lives.
content_box: *c.GtkBox,

/// The workspace sidebar.
sidebar: *Sidebar,

/// Whether the sidebar is currently visible.
sidebar_visible: bool = true,

/// Allocator
alloc: Allocator,

/// Create a new application window with workspace support.
pub fn create(gtk_app: *c.GtkApplication, app: *App) !*Window {
    const alloc = std.heap.c_allocator;

    // Create the application window
    const gtk_window: *c.GtkApplicationWindow = @ptrCast(
        c.gtk_application_window_new(gtk_app) orelse
            return error.WindowCreateFailed,
    );

    c.gtk_window_set_title(@ptrCast(gtk_window), "cmux");
    c.gtk_window_set_default_size(@ptrCast(gtk_window), 1100, 700);

    // Create the main layout: horizontal paned with sidebar on left + content on right
    const main_hbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0));
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(main_hbox)), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(main_hbox)), 1);

    // The content area where the current workspace's split tree lives
    const content_box: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0));
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(content_box)), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(content_box)), 1);

    var self = try alloc.create(Window);
    self.* = .{
        .gtk_window = gtk_window,
        .app = app,
        .tab_manager = TabManager.init(alloc),
        .pane_widgets = std.AutoHashMap(PaneTree.NodeId, *TerminalWidget).init(alloc),
        .node_widgets = std.AutoHashMap(PaneTree.NodeId, *c.GtkWidget).init(alloc),
        .content_box = content_box,
        .sidebar = undefined, // will be set below
        .alloc = alloc,
    };

    // Create the sidebar
    const sidebar = try Sidebar.create(alloc, &self.tab_manager);
    sidebar.setSelectCallback(onSidebarSelect, @ptrCast(self));
    self.sidebar = sidebar;

    // Add sidebar separator
    const sidebar_sep: *c.GtkSeparator = @ptrCast(@alignCast(c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL)));

    // Layout: sidebar | separator | content
    c.gtk_box_append(main_hbox, sidebar.widget());
    c.gtk_box_append(main_hbox, @ptrCast(@alignCast(sidebar_sep)));
    c.gtk_box_append(main_hbox, @as(*c.GtkWidget, @ptrCast(content_box)));

    c.gtk_window_set_child(@ptrCast(gtk_window), @ptrCast(main_hbox));

    // Create the first workspace with a single terminal pane
    const ws = try self.tab_manager.createWorkspace();
    try self.buildWorkspaceWidgets(ws);

    // Update sidebar to reflect the new workspace
    self.sidebar.rebuild();

    // Show the window
    c.gtk_window_present(@ptrCast(gtk_window));

    // Focus the first terminal
    if (ws.pane_tree.focused_pane) |pane_id| {
        if (self.pane_widgets.get(pane_id)) |tw| {
            _ = c.gtk_widget_grab_focus(tw.widget());
        }
    }

    log.info("Window created with sidebar", .{});

    return self;
}

/// Create a window and restore state from a session snapshot.
pub fn createFromSession(gtk_app: *c.GtkApplication, app: *App, snap: *const session.SessionSnapshot) !*Window {
    const alloc = std.heap.c_allocator;

    // Create the application window (same setup as create)
    const gtk_window: *c.GtkApplicationWindow = @ptrCast(
        c.gtk_application_window_new(gtk_app) orelse
            return error.WindowCreateFailed,
    );

    c.gtk_window_set_title(@ptrCast(gtk_window), "cmux");
    c.gtk_window_set_default_size(@ptrCast(gtk_window), 1100, 700);

    const main_hbox: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0));
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(main_hbox)), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(main_hbox)), 1);

    const content_box: *c.GtkBox = @ptrCast(c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0));
    c.gtk_widget_set_hexpand(@as(*c.GtkWidget, @ptrCast(content_box)), 1);
    c.gtk_widget_set_vexpand(@as(*c.GtkWidget, @ptrCast(content_box)), 1);

    var self = try alloc.create(Window);
    self.* = .{
        .gtk_window = gtk_window,
        .app = app,
        .tab_manager = TabManager.init(alloc),
        .pane_widgets = std.AutoHashMap(PaneTree.NodeId, *TerminalWidget).init(alloc),
        .node_widgets = std.AutoHashMap(PaneTree.NodeId, *c.GtkWidget).init(alloc),
        .content_box = content_box,
        .sidebar = undefined,
        .alloc = alloc,
    };

    const sidebar = try Sidebar.create(alloc, &self.tab_manager);
    sidebar.setSelectCallback(onSidebarSelect, @ptrCast(self));
    self.sidebar = sidebar;

    const sidebar_sep: *c.GtkSeparator = @ptrCast(@alignCast(c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL)));

    c.gtk_box_append(main_hbox, sidebar.widget());
    c.gtk_box_append(main_hbox, @ptrCast(@alignCast(sidebar_sep)));
    c.gtk_box_append(main_hbox, @as(*c.GtkWidget, @ptrCast(content_box)));
    c.gtk_window_set_child(@ptrCast(gtk_window), @ptrCast(main_hbox));

    // Restore workspaces from snapshot
    if (snap.workspaces.len == 0) {
        // No workspaces in snapshot — create a default one
        const ws = try self.tab_manager.createWorkspace();
        try self.buildWorkspaceWidgets(ws);
    } else {
        for (snap.workspaces) |*ws_snap| {
            const ws = try alloc.create(Workspace);
            ws.* = Workspace.init(alloc, ws_snap.id);
            ws.setTitle(ws_snap.title);
            if (ws_snap.cwd.len > 0) ws.setCwd(ws_snap.cwd);
            ws.pinned = ws_snap.pinned;

            // Restore pane tree layout
            _ = session.restorePaneTree(&ws.pane_tree, ws_snap) catch |err| {
                log.warn("Failed to restore pane tree for workspace {d}: {}", .{ ws_snap.id, err });
                // Fall back to a fresh root pane
                _ = ws.pane_tree.createRoot() catch {};
            };

            try self.tab_manager.workspaces.append(alloc, ws);
        }

        // Restore tab manager state
        self.tab_manager.next_id = snap.next_workspace_id;
        self.tab_manager.selected_index = if (snap.selected_workspace_index) |idx|
            if (idx < self.tab_manager.workspaces.items.len) idx else 0
        else
            0;

        // Build widgets for the selected workspace
        if (self.tab_manager.selectedWorkspace()) |ws| {
            try self.buildWorkspaceWidgets(ws);
        }
    }

    self.sidebar.rebuild();
    c.gtk_window_present(@ptrCast(gtk_window));

    // Focus the first terminal in the selected workspace
    if (self.tab_manager.selectedWorkspace()) |ws| {
        if (ws.pane_tree.focused_pane) |pane_id| {
            if (self.pane_widgets.get(pane_id)) |tw| {
                _ = c.gtk_widget_grab_focus(tw.widget());
            }
        }
    }

    log.info("Window created from session ({d} workspaces)", .{snap.workspaces.len});
    return self;
}

pub fn deinit(self: *Window) void {
    // Clean up terminal widgets
    var it = self.pane_widgets.valueIterator();
    while (it.next()) |tw| {
        tw.*.deinit();
    }
    self.pane_widgets.deinit();
    self.node_widgets.deinit();
    self.sidebar.deinit();
    self.tab_manager.deinit();
    self.alloc.destroy(self);
}

// ------------------------------------------------------------------
// Widget tree building
// ------------------------------------------------------------------

/// Build the GTK widget tree for a workspace and attach it to the content area.
fn buildWorkspaceWidgets(self: *Window, ws: *Workspace) !void {
    if (ws.pane_tree.root) |root_id| {
        const root_widget = try self.buildNodeWidget(ws, root_id);
        c.gtk_box_append(self.content_box, root_widget);
    }
}

/// Recursively build GTK widgets for a tree node.
fn buildNodeWidget(self: *Window, ws: *Workspace, node_id: PaneTree.NodeId) !*c.GtkWidget {
    const node = ws.pane_tree.getNode(node_id) orelse return error.InvalidTree;

    switch (node) {
        .pane => {
            // Create a terminal widget for this pane
            const main_mod = @import("main.zig");
            const sock_path: ?[*:0]const u8 = if (main_mod.global_server) |srv| srv.getSocketPathZ() else null;
            const tw = try TerminalWidget.create(self.app, ws.getCwd(), node_id, ws.id, sock_path);
            try self.pane_widgets.put(node_id, tw);
            const widget = tw.widget();
            try self.node_widgets.put(node_id, widget);
            return widget;
        },
        .split => |s| {
            const orientation: c_uint = switch (s.orientation) {
                .horizontal => c.GTK_ORIENTATION_HORIZONTAL,
                .vertical => c.GTK_ORIENTATION_VERTICAL,
            };

            const paned: *c.GtkPaned = @ptrCast(c.gtk_paned_new(orientation));
            const paned_widget: *c.GtkWidget = @ptrCast(@alignCast(paned));

            // Allow both children to resize
            c.gtk_paned_set_resize_start_child(paned, 1);
            c.gtk_paned_set_resize_end_child(paned, 1);
            c.gtk_paned_set_shrink_start_child(paned, 0);
            c.gtk_paned_set_shrink_end_child(paned, 0);

            c.gtk_widget_set_hexpand(paned_widget, 1);
            c.gtk_widget_set_vexpand(paned_widget, 1);

            const first_widget = try self.buildNodeWidget(ws, s.first);
            const second_widget = try self.buildNodeWidget(ws, s.second);

            c.gtk_paned_set_start_child(paned, first_widget);
            c.gtk_paned_set_end_child(paned, second_widget);

            // Defer divider positioning until the widget has a real allocation.
            setDividerOnRealize(paned, s.divider_position, s.orientation) catch {};

            try self.node_widgets.put(node_id, paned_widget);
            return paned_widget;
        },
    }
}

// ------------------------------------------------------------------
// Divider positioning
// ------------------------------------------------------------------

/// Context for deferred divider positioning on GtkPaned realize.
const DividerData = struct {
    paned: *c.GtkPaned,
    position: f64,
    orientation: PaneTree.Orientation,
};

/// Schedule proportional divider positioning after the GtkPaned is realized.
fn setDividerOnRealize(paned: *c.GtkPaned, position: f64, orientation: PaneTree.Orientation) !void {
    const alloc = std.heap.c_allocator;
    const data = try alloc.create(DividerData);
    data.* = .{
        .paned = paned,
        .position = position,
        .orientation = orientation,
    };
    _ = c.g_signal_connect_data(
        @as(c.gpointer, @ptrCast(paned)),
        "realize",
        @as(c.GCallback, @ptrCast(&onPanedRealize)),
        @ptrCast(data),
        null,
        0,
    );
}

fn onPanedRealize(_: *c.GtkWidget, userdata: c.gpointer) callconv(.c) void {
    const data: *DividerData = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(data);

    const widget: *c.GtkWidget = @ptrCast(@alignCast(data.paned));
    const size: f64 = switch (data.orientation) {
        .horizontal => @floatFromInt(c.gtk_widget_get_width(widget)),
        .vertical => @floatFromInt(c.gtk_widget_get_height(widget)),
    };

    if (size > 0) {
        c.gtk_paned_set_position(data.paned, @intFromFloat(data.position * size));
    }
}

// ------------------------------------------------------------------
// Split operations
// ------------------------------------------------------------------

/// Split the focused pane in the given direction.
pub fn splitFocused(self: *Window, direction: PaneTree.SplitDirection) !void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    const focused = ws.pane_tree.focused_pane orelse return;

    // Get the current widget for the focused pane
    const old_widget = self.node_widgets.get(focused) orelse return;

    // Perform the tree split
    const new_pane_id = try ws.pane_tree.split(focused, direction);

    // Now we need to update the GTK widget tree:
    // The old pane is now a child of a new split node.
    // Find the split node that is the parent of both.
    const pane_node = ws.pane_tree.getNode(focused) orelse return;
    const split_id = switch (pane_node) {
        .pane => |p| p.parent orelse return,
        else => return,
    };
    const split_node = ws.pane_tree.getNode(split_id) orelse return;
    const s = switch (split_node) {
        .split => |sp| sp,
        else => return,
    };

    // Create a new terminal widget for the new pane, inheriting workspace cwd
    const main_mod = @import("main.zig");
    const sock_path: ?[*:0]const u8 = if (main_mod.global_server) |srv| srv.getSocketPathZ() else null;
    const new_tw = try TerminalWidget.create(self.app, ws.getCwd(), new_pane_id, ws.id, sock_path);
    try self.pane_widgets.put(new_pane_id, new_tw);
    try self.node_widgets.put(new_pane_id, new_tw.widget());

    // Create a GtkPaned for the new split
    const orientation: c_uint = switch (s.orientation) {
        .horizontal => c.GTK_ORIENTATION_HORIZONTAL,
        .vertical => c.GTK_ORIENTATION_VERTICAL,
    };

    const paned: *c.GtkPaned = @ptrCast(c.gtk_paned_new(orientation));
    const paned_widget: *c.GtkWidget = @ptrCast(@alignCast(paned));

    c.gtk_paned_set_resize_start_child(paned, 1);
    c.gtk_paned_set_resize_end_child(paned, 1);
    c.gtk_paned_set_shrink_start_child(paned, 0);
    c.gtk_paned_set_shrink_end_child(paned, 0);
    c.gtk_widget_set_hexpand(paned_widget, 1);
    c.gtk_widget_set_vexpand(paned_widget, 1);

    // Determine child order
    const first_widget: *c.GtkWidget = if (s.first == focused) old_widget else new_tw.widget();
    const second_widget: *c.GtkWidget = if (s.second == focused) old_widget else new_tw.widget();

    // We need to remove old_widget from its current parent first.
    // Find the old parent widget and replace old_widget with the paned.
    const grandparent_id = s.parent;
    if (grandparent_id) |gid| {
        if (self.node_widgets.get(gid)) |gp_widget| {
            // It's a GtkPaned — replace the appropriate child
            const gp_paned: *c.GtkPaned = @ptrCast(gp_widget);
            // Unparent old_widget by setting start/end to null
            // then set the paned as the replacement
            // GTK4: setting a new child automatically unparents the old one
            c.gtk_paned_set_start_child(gp_paned, null);
            c.gtk_paned_set_end_child(gp_paned, null);

            // Re-read the grandparent split to determine which side
            const gp_node = ws.pane_tree.getNode(gid);
            if (gp_node) |gpn| {
                switch (gpn) {
                    .split => |gps| {
                        // Rebuild the grandparent's children
                        const gp_first = self.node_widgets.get(gps.first);
                        const gp_second = self.node_widgets.get(gps.second);
                        if (gp_first) |fw| c.gtk_paned_set_start_child(gp_paned, fw);
                        if (gp_second) |sw| c.gtk_paned_set_end_child(gp_paned, sw);
                    },
                    else => {},
                }
            }
        }
    } else {
        // Root level — remove from content_box and add paned
        c.gtk_box_remove(self.content_box, old_widget);
        c.gtk_box_append(self.content_box, paned_widget);
    }

    // Now set the children of the new paned
    c.gtk_paned_set_start_child(paned, first_widget);
    c.gtk_paned_set_end_child(paned, second_widget);

    // Set 50/50 divider position after realization
    setDividerOnRealize(paned, 0.5, s.orientation) catch {};

    try self.node_widgets.put(split_id, paned_widget);

    // Focus the new terminal
    _ = c.gtk_widget_grab_focus(new_tw.widget());

    log.info("Split created: pane {d} -> new pane {d}", .{ focused, new_pane_id });
}

/// Close the focused pane.
pub fn closeFocused(self: *Window) !void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    const focused = ws.pane_tree.focused_pane orelse return;

    // Can't close the last pane
    if (ws.pane_tree.paneCount() <= 1) return;

    // Get the terminal widget for cleanup
    const tw = self.pane_widgets.get(focused) orelse return;

    // Get parent info before closing
    const pane_node = ws.pane_tree.getNode(focused) orelse return;
    const parent_id = switch (pane_node) {
        .pane => |p| p.parent,
        else => return,
    };

    // Get the parent split info to identify sibling
    const parent_split = if (parent_id) |pid| ws.pane_tree.getNode(pid) else null;
    const sibling_id = if (parent_split) |ps| switch (ps) {
        .split => |s| if (s.first == focused) s.second else s.first,
        else => null,
    } else null;
    const grandparent_id = if (parent_split) |ps| switch (ps) {
        .split => |s| s.parent,
        else => null,
    } else null;

    // Perform the tree close
    _ = try ws.pane_tree.close(focused);

    // Update GTK widgets
    // The sibling should replace the parent split's widget
    if (parent_id) |pid| {
        const parent_widget = self.node_widgets.get(pid);
        const sibling_widget = if (sibling_id) |sid| self.node_widgets.get(sid) else null;

        if (parent_widget != null and sibling_widget != null) {
            // Unparent sibling from the old paned
            const parent_paned: *c.GtkPaned = @ptrCast(parent_widget.?);
            c.gtk_paned_set_start_child(parent_paned, null);
            c.gtk_paned_set_end_child(parent_paned, null);

            if (grandparent_id) |gid| {
                if (self.node_widgets.get(gid)) |gp_widget| {
                    const gp_paned: *c.GtkPaned = @ptrCast(gp_widget);
                    // Replace parent_widget with sibling_widget in grandparent
                    c.gtk_paned_set_start_child(gp_paned, null);
                    c.gtk_paned_set_end_child(gp_paned, null);

                    // Re-read the grandparent to set correct children
                    if (ws.pane_tree.getNode(gid)) |gpn| {
                        switch (gpn) {
                            .split => |gps| {
                                const gp_first = self.node_widgets.get(gps.first);
                                const gp_second = self.node_widgets.get(gps.second);
                                if (gp_first) |fw| c.gtk_paned_set_start_child(gp_paned, fw);
                                if (gp_second) |sw| c.gtk_paned_set_end_child(gp_paned, sw);
                            },
                            else => {},
                        }
                    }
                }
            } else {
                // Root level
                c.gtk_box_remove(self.content_box, parent_widget.?);
                c.gtk_box_append(self.content_box, sibling_widget.?);
            }
        }

        _ = self.node_widgets.remove(pid);
    }

    // Clean up the closed pane
    _ = self.pane_widgets.remove(focused);
    _ = self.node_widgets.remove(focused);
    tw.deinit();

    // Focus the next pane
    if (ws.pane_tree.focused_pane) |new_focus| {
        if (self.pane_widgets.get(new_focus)) |new_tw| {
            _ = c.gtk_widget_grab_focus(new_tw.widget());
        }
    }

    log.info("Pane {d} closed", .{focused});
}

// ------------------------------------------------------------------
// Workspace operations
// ------------------------------------------------------------------

/// Create a new workspace and switch to it.
pub fn createWorkspace(self: *Window) !void {
    // Detach current workspace's widgets
    self.detachCurrentWorkspace();

    const ws = try self.tab_manager.createWorkspace();
    self.tab_manager.selectIndex(self.tab_manager.workspaces.items.len - 1);

    try self.buildWorkspaceWidgets(ws);

    // Update sidebar
    self.sidebar.rebuild();

    if (ws.pane_tree.focused_pane) |pane_id| {
        if (self.pane_widgets.get(pane_id)) |tw| {
            _ = c.gtk_widget_grab_focus(tw.widget());
        }
    }
}

/// Switch to a workspace by index.
pub fn switchWorkspace(self: *Window, index: usize) !void {
    if (self.tab_manager.selected_index) |sel| {
        if (sel == index) return;
    }

    self.detachCurrentWorkspace();
    self.tab_manager.selectIndex(index);

    if (self.tab_manager.selectedWorkspace()) |ws| {
        try self.buildWorkspaceWidgets(ws);

        // Focus the workspace's focused pane
        if (ws.pane_tree.focused_pane) |pane_id| {
            if (self.pane_widgets.get(pane_id)) |tw| {
                _ = c.gtk_widget_grab_focus(tw.widget());
            }
        }
    }

    // Sync sidebar selection
    self.sidebar.syncSelection();
}

/// Toggle sidebar visibility.
pub fn toggleSidebar(self: *Window) void {
    self.sidebar_visible = !self.sidebar_visible;
    c.gtk_widget_set_visible(self.sidebar.widget(), if (self.sidebar_visible) 1 else 0);
}

/// Switch to the next workspace.
pub fn nextWorkspace(self: *Window) void {
    const idx = self.tab_manager.selected_index orelse return;
    if (idx + 1 < self.tab_manager.workspaces.items.len) {
        self.switchWorkspace(idx + 1) catch |err| {
            log.warn("Failed to switch to next workspace: {}", .{err});
        };
    }
}

/// Switch to the previous workspace.
pub fn previousWorkspace(self: *Window) void {
    const idx = self.tab_manager.selected_index orelse return;
    if (idx > 0) {
        self.switchWorkspace(idx - 1) catch |err| {
            log.warn("Failed to switch to previous workspace: {}", .{err});
        };
    }
}

/// Remove the current workspace's root widget from the content area.
fn detachCurrentWorkspace(self: *Window) void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    if (ws.pane_tree.root) |root_id| {
        if (self.node_widgets.get(root_id)) |root_widget| {
            c.gtk_box_remove(self.content_box, root_widget);
        }
    }
}

/// Sync GtkPaned positions to match the pane tree's divider_position values.
/// Called after pane.resize to reflect data model changes in GTK widgets.
pub fn syncDividerPositions(self: *Window, ws: *Workspace) void {
    if (ws.pane_tree.root) |root_id| {
        self.syncNodeDivider(ws, root_id);
    }
}

fn syncNodeDivider(self: *Window, ws: *Workspace, node_id: PaneTree.NodeId) void {
    const node = ws.pane_tree.getNode(node_id) orelse return;
    switch (node) {
        .pane => {},
        .split => |s| {
            if (self.node_widgets.get(node_id)) |widget| {
                const paned: *c.GtkPaned = @ptrCast(widget);
                const w: *c.GtkWidget = @ptrCast(@alignCast(paned));
                const size: f64 = switch (s.orientation) {
                    .horizontal => @floatFromInt(c.gtk_widget_get_width(w)),
                    .vertical => @floatFromInt(c.gtk_widget_get_height(w)),
                };
                if (size > 0) {
                    c.gtk_paned_set_position(paned, @intFromFloat(s.divider_position * size));
                }
            }
            self.syncNodeDivider(ws, s.first);
            self.syncNodeDivider(ws, s.second);
        },
    }
}

/// Rebuild the GTK widget tree for the current workspace, reusing existing
/// TerminalWidget instances. Used after pane.swap to reflect new layout.
pub fn rebuildCurrentWorkspace(self: *Window) !void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;

    // Detach the old root widget
    if (ws.pane_tree.root) |root_id| {
        if (self.node_widgets.get(root_id)) |root_widget| {
            c.gtk_box_remove(self.content_box, root_widget);
        }
    }

    // Clear split node widgets (pane widgets are retained)
    var to_remove: std.ArrayListUnmanaged(PaneTree.NodeId) = .{};
    defer to_remove.deinit(self.alloc);
    var it = self.node_widgets.iterator();
    while (it.next()) |entry| {
        // Only remove split node entries, keep pane entries
        if (self.pane_widgets.get(entry.key_ptr.*) == null) {
            try to_remove.append(self.alloc, entry.key_ptr.*);
        }
    }
    for (to_remove.items) |id| {
        _ = self.node_widgets.remove(id);
    }

    // Rebuild from the tree using existing terminal widgets
    if (ws.pane_tree.root) |root_id| {
        const root_widget = try self.rebuildNodeFromExisting(ws, root_id);
        c.gtk_box_append(self.content_box, root_widget);
    }
}

/// Recursively build GTK widgets from a pane tree, reusing existing TerminalWidgets.
fn rebuildNodeFromExisting(self: *Window, ws: *Workspace, node_id: PaneTree.NodeId) !*c.GtkWidget {
    const node = ws.pane_tree.getNode(node_id) orelse return error.InvalidTree;

    switch (node) {
        .pane => {
            // Reuse existing terminal widget
            const tw = self.pane_widgets.get(node_id) orelse return error.MissingWidget;
            const widget = tw.widget();
            // Unparent if it has a parent (from old tree)
            if (c.gtk_widget_get_parent(widget) != null) {
                const parent = c.gtk_widget_get_parent(widget);
                const parent_paned: *c.GtkPaned = @ptrCast(parent);
                // Clear both children to unparent
                c.gtk_paned_set_start_child(parent_paned, null);
                c.gtk_paned_set_end_child(parent_paned, null);
            }
            try self.node_widgets.put(node_id, widget);
            return widget;
        },
        .split => |s| {
            const orientation: c_uint = switch (s.orientation) {
                .horizontal => c.GTK_ORIENTATION_HORIZONTAL,
                .vertical => c.GTK_ORIENTATION_VERTICAL,
            };

            const paned: *c.GtkPaned = @ptrCast(c.gtk_paned_new(orientation));
            const paned_widget: *c.GtkWidget = @ptrCast(@alignCast(paned));

            c.gtk_paned_set_resize_start_child(paned, 1);
            c.gtk_paned_set_resize_end_child(paned, 1);
            c.gtk_paned_set_shrink_start_child(paned, 0);
            c.gtk_paned_set_shrink_end_child(paned, 0);
            c.gtk_widget_set_hexpand(paned_widget, 1);
            c.gtk_widget_set_vexpand(paned_widget, 1);

            const first_widget = try self.rebuildNodeFromExisting(ws, s.first);
            const second_widget = try self.rebuildNodeFromExisting(ws, s.second);

            c.gtk_paned_set_start_child(paned, first_widget);
            c.gtk_paned_set_end_child(paned, second_widget);

            setDividerOnRealize(paned, s.divider_position, s.orientation) catch {};

            try self.node_widgets.put(node_id, paned_widget);
            return paned_widget;
        },
    }
}

// ------------------------------------------------------------------
// Focus navigation
// ------------------------------------------------------------------

/// Navigate focus in the given direction.
pub fn navigateFocus(self: *Window, direction: PaneTree.SplitDirection) void {
    const ws = self.tab_manager.selectedWorkspace() orelse return;
    const focused = ws.pane_tree.focused_pane orelse return;

    if (ws.pane_tree.navigate(focused, direction)) |target_pane| {
        ws.pane_tree.focused_pane = target_pane;
        if (self.pane_widgets.get(target_pane)) |tw| {
            _ = c.gtk_widget_grab_focus(tw.widget());
        }
    }
}

// ------------------------------------------------------------------
// Sidebar callback
// ------------------------------------------------------------------

fn onSidebarSelect(index: usize, userdata: ?*anyopaque) void {
    const self: *Window = @ptrCast(@alignCast(userdata orelse return));
    self.switchWorkspace(index) catch |err| {
        log.warn("Failed to switch workspace: {}", .{err});
    };
}
