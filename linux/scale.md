# Terminal Resize — Root Cause & Fix

## Problem
Resizing/maximizing the cmux window did NOT cause the terminal content to visually resize. The terminal stayed at its initial dimensions.

## Root Cause
In `ghostty/src/renderer/generic.zig:drawFrame()`, there's a bail at line ~1462:

```zig
if (sync and size_changed and self.has_presented.load(.monotonic)) {
    try self.api.presentLastTarget();
    return;
}
```

This was added for macOS where CoreAnimation can synchronously request a display during bounds changes. However, on Linux (GTK), `must_draw_from_app_thread = true` means ALL draws go through the GTK render callback with `sync=true`. This bail permanently prevents `self.size.screen` from being updated (that happens at line ~1542, after the bail), creating a deadlock:

1. `size_changed` = true (viewport is new size, cached size is old)
2. `drawFrame(true)` bails → presents old frame → returns
3. `self.size.screen` never updated → `size_changed` stays true forever
4. Every subsequent frame bails

On macOS this works because the renderer thread calls `drawFrame(false)` directly, bypassing the sync bail. On Linux that path doesn't exist.

## Fix
Guarded the sync bail to Darwin only (`comptime builtin.os.tag.isDarwin()`). The cell grid check (line ~1476) already correctly handles the "cells not rebuilt yet" case on all platforms — it presents the last frame until the IO thread + renderer have rebuilt cells, then allows the draw to proceed.

## Files Modified
- `ghostty/src/renderer/generic.zig` — Darwin-only guard on sync+size_changed bail
- `linux/src/terminal_widget.zig` — removed `scheduleDelayedRenders` workaround (no longer needed)
