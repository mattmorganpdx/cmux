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

    // Pane methods
    if (std.mem.eql(u8, req.method, "pane.list")) {
        return handlePaneList(alloc, server, req);
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
        \\"surface.list","surface.send_text","surface.current",
        \\"pane.list","window.list","window.current"]}
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
