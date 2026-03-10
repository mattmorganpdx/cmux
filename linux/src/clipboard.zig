const std = @import("std");
const c = @import("c.zig");

const log = std.log.scoped(.clipboard);

/// Read from the system clipboard.
/// C typedef: void (*)(void*, ghostty_clipboard_e, void*)
pub fn readCallback(
    surface_userdata: ?*anyopaque,
    clipboard_type: c.ghostty_clipboard_e,
    request: ?*anyopaque,
) callconv(.c) void {
    _ = surface_userdata;
    _ = clipboard_type;
    _ = request;
    // TODO: Implement clipboard read via GDK.
    // Use gdk_clipboard_read_text_async for GHOSTTY_CLIPBOARD_STANDARD
    // and GDK primary selection for GHOSTTY_CLIPBOARD_SELECTION.
    // Then call ghostty_surface_complete_clipboard_request() with the result.
}

/// Confirm clipboard read (security check).
/// C typedef: void (*)(void*, const char*, void*, ghostty_clipboard_request_e)
pub fn confirmReadCallback(
    surface_userdata: ?*anyopaque,
    content: [*c]const u8,
    request: ?*anyopaque,
    request_type: c.ghostty_clipboard_request_e,
) callconv(.c) void {
    _ = surface_userdata;
    _ = content;
    _ = request;
    _ = request_type;
    // For now, auto-confirm all clipboard reads.
    // TODO: Implement confirmation dialog for large pastes.
}

/// Write to the system clipboard.
/// C typedef: void (*)(void*, ghostty_clipboard_e, const ghostty_clipboard_content_s*, size_t, bool)
pub fn writeCallback(
    surface_userdata: ?*anyopaque,
    clipboard_type: c.ghostty_clipboard_e,
    content: [*c]const c.ghostty_clipboard_content_s,
    content_len: usize,
    confirm: bool,
) callconv(.c) void {
    _ = surface_userdata;
    _ = confirm;

    if (content_len == 0) return;

    // Get the display's clipboard
    const display = c.gdk_display_get_default() orelse return;
    const clipboard = switch (clipboard_type) {
        c.GHOSTTY_CLIPBOARD_STANDARD => c.gdk_display_get_clipboard(display),
        c.GHOSTTY_CLIPBOARD_SELECTION => c.gdk_display_get_primary_clipboard(display),
        else => return,
    };

    if (clipboard == null) return;

    // Use the first content entry's data as the clipboard text
    const first = content[0];
    if (first.data != null) {
        c.gdk_clipboard_set_text(clipboard, first.data);
    }
}
