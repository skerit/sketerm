//! What activating a terminal hint does; shared by the config parser and the hint scanner.

/// `open` hands URLs to the desktop and existing files to the editor; `command` runs the rule's command.
pub const Action = enum { open, copy, paste, select, command };
