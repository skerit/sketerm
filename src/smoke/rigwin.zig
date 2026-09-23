//! Which of the display session's windows a smoke stage means.

const appdrive = @import("../ipc/appdrive.zig");

/// The GUI's first toplevel (the lowest window id). `windows.items[0]`
/// is not it once a window closed: the list is swap-removed.
pub fn mainWindow(app: *appdrive.App) ?*appdrive.Window {
    var best: ?*appdrive.Window = null;
    for (app.windows.items) |w| {
        if (w.popup) continue;
        if (best == null or w.id < best.?.id) best = w;
    }
    return best;
}

/// `mainWindow` for a caller that already knows a window exists. Stages
/// that meant "the GUI's window" used to read `windows.items[0]`, which
/// after any close is whatever the swap-remove moved there: the offload
/// stage counted a static leftover window's frames and Kill Session
/// right-clicked it.
pub fn mainWin(app: *appdrive.App) *appdrive.Window {
    return mainWindow(app) orelse app.windows.items[0];
}
