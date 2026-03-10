const std = @import("std");
const protocol = @import("protocol.zig");
const Server = @import("server.zig");
const HandleRegistry = @import("handle_registry.zig");
const Window = @import("../window.zig");
const Workspace = @import("../workspace.zig");
const PaneTree = @import("../pane_tree.zig");
const TerminalWidget = @import("../terminal_widget.zig");
const c = @import("../c.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.socket_handlers);

/// Dispatch a request to the appropriate handler.
pub fn dispatch(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    // System methods
    if (std.mem.eql(u8, req.method, "system.ping")) {
        return handleSystemPing(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "system.identify")) {
        return handleSystemIdentify(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "system.capabilities")) {
        return handleSystemCapabilities(alloc, req);
    }
    if (std.mem.eql(u8, req.method, "system.tree")) {
        return handleSystemTree(alloc, server, req);
    }

    // Workspace methods
    if (std.mem.eql(u8, req.method, "workspace.list")) {
        return handleWorkspaceList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.create")) {
        return handleWorkspaceCreate(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.current")) {
        return handleWorkspaceCurrent(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.select")) {
        return handleWorkspaceSelect(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.close")) {
        return handleWorkspaceClose(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.rename")) {
        return handleWorkspaceRename(alloc, server, req);
    }

    // Surface methods
    if (std.mem.eql(u8, req.method, "surface.list")) {
        return handleSurfaceList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.send_text")) {
        return handleSurfaceSendText(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.current")) {
        return handleSurfaceCurrent(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.read_text")) {
        return handleSurfaceReadText(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.send_key")) {
        return handleSurfaceSendKey(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.split")) {
        return handleSurfaceSplit(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "surface.close")) {
        return handleSurfaceClose(alloc, server, req);
    }

    // Workspace navigation
    if (std.mem.eql(u8, req.method, "workspace.next")) {
        return handleWorkspaceNext(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.previous")) {
        return handleWorkspacePrevious(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "workspace.last")) {
        return handleWorkspaceLast(alloc, server, req);
    }

    // Pane methods
    if (std.mem.eql(u8, req.method, "pane.list")) {
        return handlePaneList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.resize")) {
        return handlePaneResize(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "pane.swap")) {
        return handlePaneSwap(alloc, server, req);
    }

    // Window methods
    if (std.mem.eql(u8, req.method, "window.list")) {
        return handleWindowList(alloc, server, req);
    }
    if (std.mem.eql(u8, req.method, "window.current")) {
        return handleWindowCurrent(alloc, server, req);
    }

    return protocol.errorResponse(alloc, req.id, "method_not_found", req.method);
}

// ------------------------------------------------------------------
// JSON builder helpers
// ------------------------------------------------------------------

/// A simple JSON array builder that produces `[{...},{...}]`.
const JsonArrayBuilder = struct {
    buf: std.ArrayListUnmanaged(u8) = .{},
    alloc: Allocator,
    count: usize = 0,

    fn init(alloc: Allocator) JsonArrayBuilder {
        return .{ .alloc = alloc };
    }

    fn deinit(self: *JsonArrayBuilder) void {
        self.buf.deinit(self.alloc);
    }

    fn startArray(self: *JsonArrayBuilder) !void {
        try self.buf.append(self.alloc, '[');
    }

    fn endArray(self: *JsonArrayBuilder) !void {
        try self.buf.append(self.alloc, ']');
    }

    fn addRaw(self: *JsonArrayBuilder, json: []const u8) !void {
        if (self.count > 0) {
            try self.buf.append(self.alloc, ',');
        }
        try self.buf.appendSlice(self.alloc, json);
        self.count += 1;
    }

    fn toOwnedSlice(self: *JsonArrayBuilder) ![]const u8 {
        return self.buf.toOwnedSlice(self.alloc);
    }
};

/// Escape a string for JSON embedding.
fn jsonEscapeString(alloc: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
    return out.toOwnedSlice(alloc);
}

// ------------------------------------------------------------------
// System handlers
// ------------------------------------------------------------------

fn handleSystemPing(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    return protocol.successResponse(alloc, req.id, "{\"pong\":true}");
}

fn handleSystemIdentify(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window;

    // Build focused surface info
    var focused_json: []const u8 = "null";
    var focused_alloc = false;
    if (window) |w| {
        if (w.tab_manager.selectedWorkspace()) |ws| {
            if (ws.pane_tree.focused_pane) |pane_id| {
                focused_json = try std.fmt.allocPrint(alloc,
                    \\{{"workspace_id":{d},"workspace_title":"{s}","pane_id":{d}}}
                , .{ ws.id, ws.getTitle(), pane_id });
                focused_alloc = true;
            }
        }
    }
    defer if (focused_alloc) alloc.free(focused_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"socket_path":"{s}","focused":{s},"caller":null}}
    , .{ server.socket_path, focused_json });
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleSystemCapabilities(alloc: Allocator, req: *const protocol.Request) ![]const u8 {
    const methods =
        \\{"methods":["system.ping","system.identify","system.capabilities","system.tree",
        \\"workspace.list","workspace.create","workspace.current","workspace.select","workspace.close","workspace.rename",
        \\"workspace.next","workspace.previous","workspace.last",
        \\"surface.list","surface.send_text","surface.current","surface.read_text","surface.send_key","surface.split","surface.close",
        \\"pane.list","pane.resize","pane.swap",
        \\"window.list","window.current"]}
    ;
    return protocol.successResponse(alloc, req.id, methods);
}

fn handleSystemTree(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        const result =
            \\{"focused":null,"caller":null,"windows":[]}
        ;
        return protocol.successResponse(alloc, req.id, result);
    };

    // Build the tree: one window containing all workspaces
    var ws_array = JsonArrayBuilder.init(alloc);
    defer ws_array.deinit();
    try ws_array.startArray();

    const tm = &window.tab_manager;
    for (tm.workspaces.items, 0..) |ws, i| {
        const is_selected = if (tm.selected_index) |sel| sel == i else false;

        // Build pane tree for this workspace
        var pane_array = JsonArrayBuilder.init(alloc);
        defer pane_array.deinit();
        try pane_array.startArray();

        var pane_ids = try ws.pane_tree.orderedPaneIds(alloc);
        defer pane_ids.deinit(alloc);

        for (pane_ids.items) |pane_id| {
            const is_focused = if (ws.pane_tree.focused_pane) |fp| fp == pane_id else false;
            const pane_json = try std.fmt.allocPrint(alloc,
                \\{{"id":{d},"focused":{s}}}
            , .{ pane_id, if (is_focused) "true" else "false" });
            defer alloc.free(pane_json);
            try pane_array.addRaw(pane_json);
        }
        try pane_array.endArray();
        const panes_json = try pane_array.toOwnedSlice();
        defer alloc.free(panes_json);

        const title_escaped = try jsonEscapeString(alloc, ws.getTitle());
        defer alloc.free(title_escaped);

        const ws_json = try std.fmt.allocPrint(alloc,
            \\{{"id":{d},"title":"{s}","selected":{s},"pane_count":{d},"panes":{s}}}
        , .{
            ws.id,
            title_escaped,
            if (is_selected) "true" else "false",
            ws.paneCount(),
            panes_json,
        });
        defer alloc.free(ws_json);
        try ws_array.addRaw(ws_json);
    }
    try ws_array.endArray();
    const workspaces_json = try ws_array.toOwnedSlice();
    defer alloc.free(workspaces_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"focused":null,"caller":null,"windows":[{{"id":1,"workspace_count":{d},"workspaces":{s}}}]}}
    , .{ tm.workspaces.items.len, workspaces_json });
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

// ------------------------------------------------------------------
// Workspace handlers
// ------------------------------------------------------------------

fn workspaceToJson(alloc: Allocator, ws: *const Workspace, is_selected: bool, index: usize) ![]const u8 {
    const title_escaped = try jsonEscapeString(alloc, ws.getTitle());
    defer alloc.free(title_escaped);

    const git_branch = ws.getGitBranch();
    var branch_json: []const u8 = "null";
    var branch_alloc = false;
    if (git_branch) |b| {
        const escaped = try jsonEscapeString(alloc, b);
        defer alloc.free(escaped);
        branch_json = try std.fmt.allocPrint(alloc, "\"{s}\"", .{escaped});
        branch_alloc = true;
    }
    defer if (branch_alloc) alloc.free(branch_json);

    return std.fmt.allocPrint(alloc,
        \\{{"id":{d},"ref":"workspace:{d}","title":"{s}","index":{d},"selected":{s},"pinned":{s},"pane_count":{d},"git_branch":{s}}}
    , .{
        ws.id,
        ws.id,
        title_escaped,
        index,
        if (is_selected) "true" else "false",
        if (ws.pinned) "true" else "false",
        ws.paneCount(),
        branch_json,
    });
}

fn handleWorkspaceList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"workspaces\":[]}");
    };

    const tm = &window.tab_manager;

    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    for (tm.workspaces.items, 0..) |ws, i| {
        const is_selected = if (tm.selected_index) |sel| sel == i else false;
        const ws_json = try workspaceToJson(alloc, ws, is_selected, i);
        defer alloc.free(ws_json);
        try array.addRaw(ws_json);
    }

    try array.endArray();
    const ws_list = try array.toOwnedSlice();
    defer alloc.free(ws_list);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspaces":{s}}}
    , .{ws_list});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspaceCreate(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Get optional title parameter
    const title = req.getStringParam(alloc, "title");
    defer if (title) |t| alloc.free(t);

    // Create the workspace data model
    const ws = window.tab_manager.createWorkspace() catch |err| {
        return protocol.errorResponse(alloc, req.id, "create_failed", @errorName(err));
    };

    if (title) |t| {
        ws.setTitle(t);
    }

    const idx = window.tab_manager.workspaces.items.len - 1;

    // Schedule GTK widget building and switch on the main thread.
    // The workspace data model is already created; we just need to build
    // the widgets and switch the UI to it.
    const switch_ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    switch_ctx.* = .{ .window = window, .index = idx };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(switch_ctx));

    const ws_json = try workspaceToJson(alloc, ws, false, idx);
    defer alloc.free(ws_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspaceCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"workspace\":null}");
    };

    const tm = &window.tab_manager;
    const ws = tm.selectedWorkspace() orelse {
        return protocol.successResponse(alloc, req.id, "{\"workspace\":null}");
    };

    const idx = tm.selected_index orelse 0;
    const ws_json = try workspaceToJson(alloc, ws, true, idx);
    defer alloc.free(ws_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspaceSelect(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Resolve target workspace index
    var target_index: ?usize = null;

    if (req.getIntParam(alloc, "id")) |id| {
        const ws_id: u64 = @intCast(id);
        for (window.tab_manager.workspaces.items, 0..) |ws, i| {
            if (ws.id == ws_id) {
                target_index = i;
                break;
            }
        }
        if (target_index == null) {
            return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
        }
    } else if (req.getIntParam(alloc, "index")) |index| {
        const idx: usize = @intCast(index);
        if (idx >= window.tab_manager.workspaces.items.len) {
            return protocol.errorResponse(alloc, req.id, "not_found", "Invalid workspace index");
        }
        target_index = idx;
    } else {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id' or 'index' parameter");
    }

    const idx = target_index.?;

    // Schedule the workspace switch on the GTK main thread
    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .window = window,
        .index = idx,
    };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(ctx));

    // Return the workspace that will be selected
    const ws = window.tab_manager.workspaces.items[idx];
    const ws_json = try workspaceToJson(alloc, ws, true, idx);
    defer alloc.free(ws_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

const WorkspaceSwitchCtx = struct {
    window: *Window,
    index: usize,
};

fn doWorkspaceSwitch(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *WorkspaceSwitchCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);

    ctx.window.switchWorkspace(ctx.index) catch |err| {
        log.warn("Failed to switch workspace from socket: {}", .{err});
    };

    return c.G_SOURCE_REMOVE;
}

fn handleWorkspaceClose(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Validate the workspace exists before scheduling close
    var close_id: ?u64 = null;
    var close_index: ?usize = null;

    if (req.getIntParam(alloc, "id")) |id| {
        const ws_id: u64 = @intCast(id);
        for (window.tab_manager.workspaces.items, 0..) |ws, i| {
            if (ws.id == ws_id) {
                close_id = ws_id;
                close_index = i;
                break;
            }
        }
        if (close_id == null) {
            return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
        }
    } else if (req.getIntParam(alloc, "index")) |index| {
        const idx: usize = @intCast(index);
        if (idx >= window.tab_manager.workspaces.items.len) {
            return protocol.errorResponse(alloc, req.id, "not_found", "Invalid workspace index");
        }
        close_index = idx;
    } else {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'id' or 'index' parameter");
    }

    // Schedule close on main thread (tab_manager + sidebar rebuild)
    const ctx = std.heap.c_allocator.create(WorkspaceCloseCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .window = window,
        .index = close_index.?,
        .id = close_id,
    };
    _ = c.g_idle_add(&doWorkspaceClose, @ptrCast(ctx));

    return protocol.successResponse(alloc, req.id, "{\"closed\":true}");
}

const WorkspaceCloseCtx = struct {
    window: *Window,
    index: usize,
    id: ?u64,
};

fn doWorkspaceClose(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *WorkspaceCloseCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);

    if (ctx.id) |id| {
        _ = ctx.window.tab_manager.closeWorkspaceById(@intCast(id));
    } else {
        _ = ctx.window.tab_manager.closeWorkspace(ctx.index);
    }

    // Rebuild sidebar to reflect the change
    ctx.window.sidebar.rebuild();

    return c.G_SOURCE_REMOVE;
}

fn handleWorkspaceRename(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const new_title = req.getStringParam(alloc, "title") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'title' parameter");
    };
    defer alloc.free(new_title);

    // Find workspace by id or use current
    var ws: ?*Workspace = null;
    if (req.getIntParam(alloc, "id")) |id| {
        ws = window.tab_manager.findById(@intCast(id));
    } else {
        ws = window.tab_manager.selectedWorkspace();
    }

    if (ws) |w| {
        w.setTitle(new_title);
        return protocol.successResponse(alloc, req.id, "{\"renamed\":true}");
    }

    return protocol.errorResponse(alloc, req.id, "not_found", "Workspace not found");
}

// ------------------------------------------------------------------
// Surface handlers
// ------------------------------------------------------------------

fn handleSurfaceList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"surfaces\":[]}");
    };

    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    const tm = &window.tab_manager;
    for (tm.workspaces.items) |ws| {
        var pane_ids = try ws.pane_tree.orderedPaneIds(alloc);
        defer pane_ids.deinit(alloc);

        for (pane_ids.items) |pane_id| {
            const is_focused = if (ws.pane_tree.focused_pane) |fp| fp == pane_id else false;
            const has_surface = window.pane_widgets.get(pane_id) != null;

            const surface_json = try std.fmt.allocPrint(alloc,
                \\{{"id":{d},"ref":"surface:{d}","workspace_id":{d},"pane_id":{d},"focused":{s},"alive":{s}}}
            , .{
                pane_id,
                pane_id,
                ws.id,
                pane_id,
                if (is_focused) "true" else "false",
                if (has_surface) "true" else "false",
            });
            defer alloc.free(surface_json);
            try array.addRaw(surface_json);
        }
    }

    try array.endArray();
    const surfaces_json = try array.toOwnedSlice();
    defer alloc.free(surfaces_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"surfaces":{s}}}
    , .{surfaces_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleSurfaceCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    };

    const ws = window.tab_manager.selectedWorkspace() orelse {
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    };

    const pane_id = ws.pane_tree.focused_pane orelse {
        return protocol.successResponse(alloc, req.id, "{\"surface\":null}");
    };

    const has_surface = window.pane_widgets.get(pane_id) != null;

    const surface_json = try std.fmt.allocPrint(alloc,
        \\{{"surface":{{"id":{d},"ref":"surface:{d}","workspace_id":{d},"pane_id":{d},"focused":true,"alive":{s}}}}}
    , .{
        pane_id,
        pane_id,
        ws.id,
        pane_id,
        if (has_surface) "true" else "false",
    });
    defer alloc.free(surface_json);
    return protocol.successResponse(alloc, req.id, surface_json);
}

fn handleSurfaceSendText(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const text = req.getStringParam(alloc, "text") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'text' parameter");
    };
    defer alloc.free(text);

    // Find the target surface: by surface_id param, or use the focused surface
    var target_pane_id: ?PaneTree.NodeId = null;
    if (req.getIntParam(alloc, "surface_id")) |sid| {
        target_pane_id = @intCast(sid);
    } else {
        // Use focused surface in current workspace
        if (window.tab_manager.selectedWorkspace()) |ws| {
            target_pane_id = ws.pane_tree.focused_pane;
        }
    }

    const pane_id = target_pane_id orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    };

    const tw = window.pane_widgets.get(pane_id) orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface widget not found");
    };

    if (tw.surface == null) {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface not initialized");
    }

    // Use ghostty_surface_binding_action with "text:" prefix to write directly
    // to the PTY. This avoids bracketed paste mode (which ghostty_surface_text
    // uses) so that control characters like \n are properly interpreted by the
    // shell as Enter.
    //
    // The "text:" binding action expects Zig string literal escape syntax, so
    // we encode control characters (< 0x20) and DEL (0x7f) as \xHH sequences.
    // Printable ASCII and valid UTF-8 sequences are passed through as-is.
    const action_str = try encodeBindingActionText(alloc, text);
    defer alloc.free(action_str);

    _ = c.ghostty_surface_binding_action(tw.surface, action_str.ptr, action_str.len);

    log.info("send_text to pane {d}: {d} bytes", .{ pane_id, text.len });

    const result = try std.fmt.allocPrint(alloc,
        \\{{"queued":true,"surface_id":{d}}}
    , .{pane_id});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

/// Encode text as a Ghostty binding action string: "text:<zig-escaped-content>".
/// Control characters (< 0x20, 0x7F) are escaped as \xHH.
/// Backslashes are escaped as \\.
/// All other bytes (printable ASCII, UTF-8) are passed through.
fn encodeBindingActionText(alloc: Allocator, text: []const u8) ![]const u8 {
    const prefix = "text:";
    // Worst case: every byte becomes \xHH (4 chars), plus prefix
    var buf = try alloc.alloc(u8, prefix.len + text.len * 4);
    errdefer alloc.free(buf);

    @memcpy(buf[0..prefix.len], prefix);
    var pos: usize = prefix.len;

    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7F) {
            // Control characters: encode as \xHH
            buf[pos] = '\\';
            buf[pos + 1] = 'x';
            buf[pos + 2] = hexDigit(byte >> 4);
            buf[pos + 3] = hexDigit(byte & 0x0f);
            pos += 4;
        } else if (byte == '\\') {
            // Escape backslashes
            buf[pos] = '\\';
            buf[pos + 1] = '\\';
            pos += 2;
        } else {
            // Printable ASCII and UTF-8 continuation bytes: pass through
            buf[pos] = byte;
            pos += 1;
        }
    }

    // Shrink to actual size
    const result = try alloc.realloc(buf, pos);
    return result;
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
}

// ------------------------------------------------------------------
// surface.read_text — read terminal content via Ghostty API
// ------------------------------------------------------------------

const ReadTextCtx = struct {
    surface: c.ghostty_surface_t,
    include_scrollback: bool,
    // Output fields — written by main thread, read by handler thread
    result_text: ?[*]const u8 = null,
    result_len: usize = 0,
    success: bool = false,
    done: std.Thread.ResetEvent = .{},
};

fn handleSurfaceReadText(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    // Resolve target surface
    var target_pane_id: ?PaneTree.NodeId = null;
    if (req.getIntParam(alloc, "surface_id")) |sid| {
        target_pane_id = @intCast(sid);
    } else {
        if (window.tab_manager.selectedWorkspace()) |ws| {
            target_pane_id = ws.pane_tree.focused_pane;
        }
    }

    const pane_id = target_pane_id orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    };

    const tw = window.pane_widgets.get(pane_id) orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface widget not found");
    };

    if (tw.surface == null) {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface not initialized");
    }

    const include_scrollback = req.getBoolParam(alloc, "scrollback") orelse false;

    // Dispatch to GTK main thread and block until complete
    const ctx = std.heap.c_allocator.create(ReadTextCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .surface = tw.surface,
        .include_scrollback = include_scrollback,
    };
    _ = c.g_idle_add(&doReadText, @ptrCast(ctx));

    // Block until the main thread callback completes
    ctx.done.wait();

    // Read results (main thread is done writing)
    const success = ctx.success;
    const result_text = ctx.result_text;
    const result_len = ctx.result_len;
    std.heap.c_allocator.destroy(ctx);

    if (!success) {
        return protocol.errorResponse(alloc, req.id, "read_failed", "Failed to read terminal text");
    }

    // Build JSON response with the text
    if (result_text) |text_ptr| {
        const text_slice = text_ptr[0..result_len];
        defer std.heap.c_allocator.free(text_slice);

        // JSON-escape the text
        var escaped: std.ArrayListUnmanaged(u8) = .{};
        defer escaped.deinit(alloc);
        for (text_slice) |ch| {
            switch (ch) {
                '"' => try escaped.appendSlice(alloc, "\\\""),
                '\\' => try escaped.appendSlice(alloc, "\\\\"),
                '\n' => try escaped.appendSlice(alloc, "\\n"),
                '\r' => try escaped.appendSlice(alloc, "\\r"),
                '\t' => try escaped.appendSlice(alloc, "\\t"),
                else => {
                    if (ch < 0x20) {
                        var buf: [6]u8 = undefined;
                        const hex_str = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch continue;
                        try escaped.appendSlice(alloc, hex_str);
                    } else {
                        try escaped.append(alloc, ch);
                    }
                },
            }
        }

        const result = try std.fmt.allocPrint(alloc,
            \\{{"text":"{s}","surface_id":{d}}}
        , .{ escaped.items, pane_id });
        defer alloc.free(result);
        return protocol.successResponse(alloc, req.id, result);
    }

    const result = try std.fmt.allocPrint(alloc,
        \\{{"text":"","surface_id":{d}}}
    , .{pane_id});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn doReadText(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *ReadTextCtx = @ptrCast(@alignCast(userdata));
    // Do NOT defer destroy — the handler thread still needs ctx
    defer ctx.done.set();

    if (ctx.surface == null) return c.G_SOURCE_REMOVE;

    const point_tag: c.ghostty_point_tag_e = if (ctx.include_scrollback)
        c.GHOSTTY_POINT_SCREEN
    else
        c.GHOSTTY_POINT_VIEWPORT;

    var selection: c.ghostty_selection_s = std.mem.zeroes(c.ghostty_selection_s);
    selection.top_left.tag = point_tag;
    selection.top_left.coord = c.GHOSTTY_POINT_COORD_TOP_LEFT;
    selection.top_left.x = 0;
    selection.top_left.y = 0;
    selection.bottom_right.tag = point_tag;
    selection.bottom_right.coord = c.GHOSTTY_POINT_COORD_BOTTOM_RIGHT;
    selection.bottom_right.x = 0;
    selection.bottom_right.y = 0;
    selection.rectangle = true;

    var text: c.ghostty_text_s = std.mem.zeroes(c.ghostty_text_s);
    if (c.ghostty_surface_read_text(ctx.surface, selection, &text)) {
        defer c.ghostty_surface_free_text(ctx.surface, &text);
        if (text.text != null and text.text_len > 0) {
            // Copy text into heap-allocated buffer for the handler thread
            const slice = text.text[0..text.text_len];
            const copy = std.heap.c_allocator.alloc(u8, text.text_len) catch {
                return c.G_SOURCE_REMOVE;
            };
            @memcpy(copy, slice);
            ctx.result_text = copy.ptr;
            ctx.result_len = text.text_len;
        }
        ctx.success = true;
    }

    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// surface.send_key — send individual keystrokes
// ------------------------------------------------------------------

fn handleSurfaceSendKey(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const key = req.getStringParam(alloc, "key") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'key' parameter");
    };
    defer alloc.free(key);

    // Resolve target surface
    var target_pane_id: ?PaneTree.NodeId = null;
    if (req.getIntParam(alloc, "surface_id")) |sid| {
        target_pane_id = @intCast(sid);
    } else {
        if (window.tab_manager.selectedWorkspace()) |ws| {
            target_pane_id = ws.pane_tree.focused_pane;
        }
    }

    const pane_id = target_pane_id orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "No target surface found");
    };

    const tw = window.pane_widgets.get(pane_id) orelse {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface widget not found");
    };

    if (tw.surface == null) {
        return protocol.errorResponse(alloc, req.id, "no_surface", "Surface not initialized");
    }

    const action_bytes = resolveKeyAction(alloc, key) orelse {
        return protocol.errorResponse(alloc, req.id, "unknown_key", "Unknown key name");
    };
    defer alloc.free(action_bytes);

    _ = c.ghostty_surface_binding_action(tw.surface, action_bytes.ptr, action_bytes.len);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"sent":true,"key":"{s}","surface_id":{d}}}
    , .{ key, pane_id });
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

/// Map a named key to a Ghostty binding action string.
fn resolveKeyAction(alloc: Allocator, key_name: []const u8) ?[]const u8 {
    // Normalize to lowercase
    var lower_buf: [64]u8 = undefined;
    if (key_name.len > lower_buf.len) return null;
    for (key_name, 0..) |ch, i| {
        lower_buf[i] = if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
    }
    const lower = lower_buf[0..key_name.len];

    const eql = std.mem.eql;

    // Map key names to binding action strings
    const seq: ?[]const u8 = if (eql(u8, lower, "ctrl-c") or eql(u8, lower, "ctrl+c"))
        "text:\\x03"
    else if (eql(u8, lower, "ctrl-d") or eql(u8, lower, "ctrl+d"))
        "text:\\x04"
    else if (eql(u8, lower, "ctrl-z") or eql(u8, lower, "ctrl+z"))
        "text:\\x1a"
    else if (eql(u8, lower, "ctrl-\\") or eql(u8, lower, "ctrl+\\"))
        "text:\\x1c"
    else if (eql(u8, lower, "ctrl-a") or eql(u8, lower, "ctrl+a"))
        "text:\\x01"
    else if (eql(u8, lower, "ctrl-e") or eql(u8, lower, "ctrl+e"))
        "text:\\x05"
    else if (eql(u8, lower, "ctrl-l") or eql(u8, lower, "ctrl+l"))
        "text:\\x0c"
    else if (eql(u8, lower, "ctrl-r") or eql(u8, lower, "ctrl+r"))
        "text:\\x12"
    else if (eql(u8, lower, "ctrl-u") or eql(u8, lower, "ctrl+u"))
        "text:\\x15"
    else if (eql(u8, lower, "ctrl-w") or eql(u8, lower, "ctrl+w"))
        "text:\\x17"
    else if (eql(u8, lower, "enter") or eql(u8, lower, "return"))
        "text:\\x0d"
    else if (eql(u8, lower, "tab"))
        "text:\\x09"
    else if (eql(u8, lower, "escape") or eql(u8, lower, "esc"))
        "text:\\x1b"
    else if (eql(u8, lower, "backspace"))
        "text:\\x7f"
    else if (eql(u8, lower, "space"))
        "text:\\x20"
    else if (eql(u8, lower, "up") or eql(u8, lower, "arrow_up"))
        "text:\\x1b[A"
    else if (eql(u8, lower, "down") or eql(u8, lower, "arrow_down"))
        "text:\\x1b[B"
    else if (eql(u8, lower, "right") or eql(u8, lower, "arrow_right"))
        "text:\\x1b[C"
    else if (eql(u8, lower, "left") or eql(u8, lower, "arrow_left"))
        "text:\\x1b[D"
    else if (eql(u8, lower, "home"))
        "text:\\x1b[H"
    else if (eql(u8, lower, "end"))
        "text:\\x1b[F"
    else if (eql(u8, lower, "page_up") or eql(u8, lower, "pageup"))
        "text:\\x1b[5~"
    else if (eql(u8, lower, "page_down") or eql(u8, lower, "pagedown"))
        "text:\\x1b[6~"
    else if (eql(u8, lower, "delete") or eql(u8, lower, "del"))
        "text:\\x1b[3~"
    else if (eql(u8, lower, "insert"))
        "text:\\x1b[2~"
    else blk: {
        // Generic ctrl-<letter> pattern
        if (lower.len >= 6 and (eql(u8, lower[0..5], "ctrl-") or eql(u8, lower[0..5], "ctrl+"))) {
            const letter = lower[5..];
            if (letter.len == 1 and letter[0] >= 'a' and letter[0] <= 'z') {
                const ctrl_byte = letter[0] - 'a' + 1;
                return std.fmt.allocPrint(alloc, "text:\\x{x:0>2}", .{ctrl_byte}) catch null;
            }
        }
        break :blk null;
    };

    if (seq) |s| {
        return alloc.dupe(u8, s) catch null;
    }
    return null;
}

// ------------------------------------------------------------------
// surface.split — create splits via socket
// ------------------------------------------------------------------

const SplitCtx = struct {
    window: *Window,
    direction: PaneTree.SplitDirection,
};

fn handleSurfaceSplit(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const dir_str = req.getStringParam(alloc, "direction") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'direction' parameter");
    };
    defer alloc.free(dir_str);

    const direction = parseDirection(dir_str) orelse {
        return protocol.errorResponse(alloc, req.id, "invalid_param", "direction must be left/right/up/down");
    };

    const ctx = std.heap.c_allocator.create(SplitCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .direction = direction };
    _ = c.g_idle_add(&doSplit, @ptrCast(ctx));

    return protocol.successResponse(alloc, req.id, "{\"split\":true}");
}

fn doSplit(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *SplitCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);
    ctx.window.splitFocused(ctx.direction) catch |err| {
        log.warn("Failed to split from socket: {}", .{err});
    };
    return c.G_SOURCE_REMOVE;
}

fn parseDirection(dir_str: []const u8) ?PaneTree.SplitDirection {
    if (std.mem.eql(u8, dir_str, "left")) return .left;
    if (std.mem.eql(u8, dir_str, "right")) return .right;
    if (std.mem.eql(u8, dir_str, "up")) return .up;
    if (std.mem.eql(u8, dir_str, "down")) return .down;
    return null;
}

// ------------------------------------------------------------------
// surface.close — close pane via socket
// ------------------------------------------------------------------

fn handleSurfaceClose(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const ws = window.tab_manager.selectedWorkspace() orelse {
        return protocol.errorResponse(alloc, req.id, "no_workspace", "No workspace selected");
    };

    // Guard: can't close the last pane
    if (ws.pane_tree.paneCount() <= 1) {
        return protocol.errorResponse(alloc, req.id, "last_pane", "Cannot close the last pane");
    }

    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    // Reuse WorkspaceSwitchCtx — we just need the window pointer
    ctx.* = .{ .window = window, .index = 0 };
    _ = c.g_idle_add(&doCloseSurface, @ptrCast(ctx));

    return protocol.successResponse(alloc, req.id, "{\"closed\":true}");
}

fn doCloseSurface(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *WorkspaceSwitchCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);
    ctx.window.closeFocused() catch |err| {
        log.warn("Failed to close surface from socket: {}", .{err});
    };
    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// workspace.next / workspace.previous / workspace.last
// ------------------------------------------------------------------

fn handleWorkspaceNext(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const tm = &window.tab_manager;
    const idx = tm.selected_index orelse {
        return protocol.errorResponse(alloc, req.id, "no_workspace", "No workspace selected");
    };

    if (idx + 1 >= tm.workspaces.items.len) {
        return protocol.errorResponse(alloc, req.id, "at_end", "Already at last workspace");
    }

    const next_idx = idx + 1;
    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .index = next_idx };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(ctx));

    const ws = tm.workspaces.items[next_idx];
    const ws_json = try workspaceToJson(alloc, ws, true, next_idx);
    defer alloc.free(ws_json);
    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspacePrevious(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const tm = &window.tab_manager;
    const idx = tm.selected_index orelse {
        return protocol.errorResponse(alloc, req.id, "no_workspace", "No workspace selected");
    };

    if (idx == 0) {
        return protocol.errorResponse(alloc, req.id, "at_start", "Already at first workspace");
    }

    const prev_idx = idx - 1;
    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .index = prev_idx };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(ctx));

    const ws = tm.workspaces.items[prev_idx];
    const ws_json = try workspaceToJson(alloc, ws, true, prev_idx);
    defer alloc.free(ws_json);
    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWorkspaceLast(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const tm = &window.tab_manager;
    if (tm.history.items.len == 0) {
        return protocol.errorResponse(alloc, req.id, "no_history", "No workspace history");
    }

    const last_id = tm.history.items[tm.history.items.len - 1];

    // Find index for this workspace ID
    var target_index: ?usize = null;
    for (tm.workspaces.items, 0..) |ws, i| {
        if (ws.id == last_id) {
            target_index = i;
            break;
        }
    }

    const idx = target_index orelse {
        return protocol.errorResponse(alloc, req.id, "not_found", "Last workspace no longer exists");
    };

    const ctx = std.heap.c_allocator.create(WorkspaceSwitchCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{ .window = window, .index = idx };
    _ = c.g_idle_add(&doWorkspaceSwitch, @ptrCast(ctx));

    const ws = tm.workspaces.items[idx];
    const ws_json = try workspaceToJson(alloc, ws, true, idx);
    defer alloc.free(ws_json);
    const result = try std.fmt.allocPrint(alloc,
        \\{{"workspace":{s}}}
    , .{ws_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

// ------------------------------------------------------------------
// pane.resize — resize pane divider via socket
// ------------------------------------------------------------------

const PaneResizeCtx = struct {
    window: *Window,
    pane_id: PaneTree.NodeId,
    direction: PaneTree.SplitDirection,
    delta: f64,
};

fn handlePaneResize(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const pane_id_raw = req.getIntParam(alloc, "pane_id") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pane_id' parameter");
    };

    const dir_str = req.getStringParam(alloc, "direction") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'direction' parameter");
    };
    defer alloc.free(dir_str);

    const direction = parseDirection(dir_str) orelse {
        return protocol.errorResponse(alloc, req.id, "invalid_param", "direction must be left/right/up/down");
    };

    const amount = req.getFloatParam(alloc, "amount") orelse 0.1;

    const ctx = std.heap.c_allocator.create(PaneResizeCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .window = window,
        .pane_id = @intCast(pane_id_raw),
        .direction = direction,
        .delta = amount,
    };
    _ = c.g_idle_add(&doPaneResize, @ptrCast(ctx));

    return protocol.successResponse(alloc, req.id, "{\"resized\":true}");
}

fn doPaneResize(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *PaneResizeCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);

    const ws = ctx.window.tab_manager.selectedWorkspace() orelse return c.G_SOURCE_REMOVE;

    ws.pane_tree.resize(ctx.pane_id, ctx.direction, ctx.delta) catch |err| {
        log.warn("Failed to resize pane {d}: {}", .{ ctx.pane_id, err });
        return c.G_SOURCE_REMOVE;
    };

    // Sync GTK widget positions to match updated data model
    ctx.window.syncDividerPositions(ws);

    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// pane.swap — swap two panes via socket
// ------------------------------------------------------------------

const PaneSwapCtx = struct {
    window: *Window,
    pane_a: PaneTree.NodeId,
    pane_b: PaneTree.NodeId,
};

fn handlePaneSwap(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.errorResponse(alloc, req.id, "no_window", "No window available");
    };

    const pane_a_raw = req.getIntParam(alloc, "pane_a") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pane_a' parameter");
    };
    const pane_b_raw = req.getIntParam(alloc, "pane_b") orelse {
        return protocol.errorResponse(alloc, req.id, "missing_param", "Requires 'pane_b' parameter");
    };

    const ctx = std.heap.c_allocator.create(PaneSwapCtx) catch {
        return protocol.errorResponse(alloc, req.id, "internal_error", "Failed to allocate context");
    };
    ctx.* = .{
        .window = window,
        .pane_a = @intCast(pane_a_raw),
        .pane_b = @intCast(pane_b_raw),
    };
    _ = c.g_idle_add(&doPaneSwap, @ptrCast(ctx));

    return protocol.successResponse(alloc, req.id, "{\"swapped\":true}");
}

fn doPaneSwap(userdata: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *PaneSwapCtx = @ptrCast(@alignCast(userdata));
    defer std.heap.c_allocator.destroy(ctx);

    const ws = ctx.window.tab_manager.selectedWorkspace() orelse return c.G_SOURCE_REMOVE;

    // Perform data model swap
    ws.pane_tree.swap(ctx.pane_a, ctx.pane_b) catch |err| {
        log.warn("Failed to swap panes: {}", .{err});
        return c.G_SOURCE_REMOVE;
    };

    // Swap widget registrations
    const widget_a = ctx.window.pane_widgets.get(ctx.pane_a);
    const widget_b = ctx.window.pane_widgets.get(ctx.pane_b);
    if (widget_a) |wa| ctx.window.pane_widgets.put(ctx.pane_b, wa) catch {};
    if (widget_b) |wb| ctx.window.pane_widgets.put(ctx.pane_a, wb) catch {};

    const nw_a = ctx.window.node_widgets.get(ctx.pane_a);
    const nw_b = ctx.window.node_widgets.get(ctx.pane_b);
    if (nw_a) |na| ctx.window.node_widgets.put(ctx.pane_b, na) catch {};
    if (nw_b) |nb| ctx.window.node_widgets.put(ctx.pane_a, nb) catch {};

    // Rebuild GTK widget tree to reflect new layout
    ctx.window.rebuildCurrentWorkspace() catch |err| {
        log.warn("Failed to rebuild workspace after swap: {}", .{err});
    };

    return c.G_SOURCE_REMOVE;
}

// ------------------------------------------------------------------
// Pane handlers
// ------------------------------------------------------------------

fn handlePaneList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"panes\":[]}");
    };

    var array = JsonArrayBuilder.init(alloc);
    defer array.deinit();
    try array.startArray();

    const tm = &window.tab_manager;

    // Optionally filter by workspace_id
    const filter_ws_id = req.getIntParam(alloc, "workspace_id");

    for (tm.workspaces.items) |ws| {
        if (filter_ws_id) |fid| {
            if (ws.id != @as(u64, @intCast(fid))) continue;
        }

        var pane_ids = try ws.pane_tree.orderedPaneIds(alloc);
        defer pane_ids.deinit(alloc);

        for (pane_ids.items) |pane_id| {
            const is_focused = if (ws.pane_tree.focused_pane) |fp| fp == pane_id else false;

            const pane_json = try std.fmt.allocPrint(alloc,
                \\{{"id":{d},"ref":"pane:{d}","workspace_id":{d},"focused":{s},"surface_count":1}}
            , .{
                pane_id,
                pane_id,
                ws.id,
                if (is_focused) "true" else "false",
            });
            defer alloc.free(pane_json);
            try array.addRaw(pane_json);
        }
    }

    try array.endArray();
    const panes_json = try array.toOwnedSlice();
    defer alloc.free(panes_json);

    const result = try std.fmt.allocPrint(alloc,
        \\{{"panes":{s}}}
    , .{panes_json});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

// ------------------------------------------------------------------
// Window handlers
// ------------------------------------------------------------------

fn handleWindowList(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"windows\":[]}");
    };

    const ws_count = window.tab_manager.workspaces.items.len;
    const result = try std.fmt.allocPrint(alloc,
        \\{{"windows":[{{"id":1,"ref":"window:1","focused":true,"workspace_count":{d}}}]}}
    , .{ws_count});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}

fn handleWindowCurrent(alloc: Allocator, server: *Server, req: *const protocol.Request) ![]const u8 {
    const window = server.window orelse {
        return protocol.successResponse(alloc, req.id, "{\"window\":null}");
    };

    const ws_count = window.tab_manager.workspaces.items.len;
    const result = try std.fmt.allocPrint(alloc,
        \\{{"window":{{"id":1,"ref":"window:1","focused":true,"workspace_count":{d}}}}}
    , .{ws_count});
    defer alloc.free(result);
    return protocol.successResponse(alloc, req.id, result);
}
