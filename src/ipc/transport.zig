//! How an MCP terminal reaches its host: the one vocabulary `term_open`
//! and the `agent_*` tools share, for the `transport` argument they take
//! and the `transport` fact they report (schemas derive from these enums).

/// The `transport` argument of a remote open.
pub const Choice = enum {
    /// The host's own sketerm-mux daemon when it answers, else plain ssh.
    auto,
    /// Require the remote daemon (an error instead of falling back).
    mux,
    /// Never probe for it: plain interactive `ssh -tt`.
    ssh,
};

/// What a terminal actually runs over, as results report it.
pub const Transport = enum {
    /// A session on this server's private daemon, on this machine.
    local,
    /// `ssh -tt` running in a local session: the remote process ends with
    /// the connection.
    ssh,
    /// A session on the remote host's own daemon: it survives connection
    /// drops and is reattached.
    @"sketerm-mux",
};
