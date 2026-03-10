const std = @import("std");
const PaneTree = @import("pane_tree.zig");

const log = std.log.scoped(.workspace);

/// A workspace groups a set of panes (split layout) together.
/// Workspaces are shown in the sidebar and can be switched between.
pub const Workspace = @This();

const Allocator = std.mem.Allocator;

pub const WorkspaceId = u64;

id: WorkspaceId,
title: [256]u8 = [_]u8{0} ** 256,
title_len: usize = 0,
pinned: bool = false,

/// The pane tree managing the split layout for this workspace.
pane_tree: PaneTree,

/// Working directory for new terminals in this workspace.
cwd: ?[*:0]const u8 = null,

/// Git branch name (polled from cwd).
git_branch: [128]u8 = [_]u8{0} ** 128,
git_branch_len: usize = 0,

pub fn init(alloc: Allocator, id: WorkspaceId) Workspace {
    return .{
        .id = id,
        .pane_tree = PaneTree.init(alloc),
    };
}

pub fn deinit(self: *Workspace) void {
    self.pane_tree.deinit();
}

pub fn setTitle(self: *Workspace, title: []const u8) void {
    const len = @min(title.len, self.title.len);
    @memcpy(self.title[0..len], title[0..len]);
    self.title_len = len;
}

pub fn getTitle(self: *const Workspace) []const u8 {
    if (self.title_len == 0) {
        return "Workspace";
    }
    return self.title[0..self.title_len];
}

pub fn setGitBranch(self: *Workspace, branch: []const u8) void {
    const len = @min(branch.len, self.git_branch.len);
    @memcpy(self.git_branch[0..len], branch[0..len]);
    self.git_branch_len = len;
}

pub fn getGitBranch(self: *const Workspace) ?[]const u8 {
    if (self.git_branch_len == 0) return null;
    return self.git_branch[0..self.git_branch_len];
}

/// Get the number of panes in this workspace.
pub fn paneCount(self: *const Workspace) usize {
    return self.pane_tree.paneCount();
}
