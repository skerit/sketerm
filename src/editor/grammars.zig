//! The Tree-sitter grammars: the ONE list `build.zig` fetches and
//! compiles and `syntax.zig` binds, so a grammar cannot be built without
//! being reachable or bound without being built.
//!
//! Pure data, std-only, and imported by `build.zig` itself; it must
//! stay free of anything a build script cannot compile. No grammar
//! source lives in this repository: each `Upstream` is a GitHub archive
//! pinned by commit and SHA-256 that the build downloads the first time
//! a GUI or test target needs it (never for `sketerm-mux`). A grammar's
//! C entry point is `tree_sitter_<tag>()`, and each `Query` is embedded
//! as the anonymous import `ts_query_<tag>`.

const std = @import("std");

/// One pinned upstream source tree; a repository hosting several
/// grammars (typescript + tsx, markdown + markdown_inline) is one member.
pub const Upstream = enum {
    zig,
    c,
    cpp,
    json,
    markdown,
    python,
    rust,
    javascript,
    typescript,
    bash,
    go,
    html,
    css,
    toml,
    yaml,
    lua,
    make,
    java,
    diff,
    xml,
    dockerfile,

    pub const Pin = struct {
        /// `owner/name` on GitHub.
        repo: []const u8,
        commit: []const u8,
        /// Of the archive tarball, which GitHub serves byte-stable per commit.
        sha256: []const u8,
    };

    pub fn pin(self: Upstream) Pin {
        return switch (self) {
            .zig => .{ .repo = "tree-sitter-grammars/tree-sitter-zig", .commit = "6479aa13f32f701c383083d8b28360ebd682fb7d", .sha256 = "34b338658c7548ea7e723b9a74a18bba76d16bf453bc4a9deb13f2f507f4e725" },
            .c => .{ .repo = "tree-sitter/tree-sitter-c", .commit = "b780e47fc780ddc8da13afa35a3f4ed5c157823d", .sha256 = "dc3979e40fce678c27273ba8ab93b48b5acd6b91d1dfde6a4451222d366d689f" },
            .cpp => .{ .repo = "tree-sitter/tree-sitter-cpp", .commit = "c009222808634c1014f82438d4883753516a2c24", .sha256 = "6c6efaf024f5c02fee0403e4e2373346eeadc40828587bcfad9351df2f0a7986" },
            .json => .{ .repo = "tree-sitter/tree-sitter-json", .commit = "001c28d7a29832b06b0e831ec77845553c89b56d", .sha256 = "a4e0b901a42b37bde6b6ff1841d3d37f508732138b84c389f6971f8e3b7f7848" },
            .markdown => .{ .repo = "tree-sitter-grammars/tree-sitter-markdown", .commit = "a0a00f817d02412bd92c54d316f164d827b57b5c", .sha256 = "a712569a59f127fd44a1cb59eecdb05d63fa2ccb4622b7d822bff199bf6fb133" },
            .python => .{ .repo = "tree-sitter/tree-sitter-python", .commit = "26855eabccb19c6abf499fbc5b8dc7cc9ab8bc64", .sha256 = "43e71c4d0cbbd2350e83e0b2da3558eab09b8dc78153a8990508b0c9eec754e6" },
            .rust => .{ .repo = "tree-sitter/tree-sitter-rust", .commit = "77a3747266f4d621d0757825e6b11edcbf991ca5", .sha256 = "dee82ddfd01bfc3a8ed201cc03b56448107d3217a4b3a7a8fc7fa6bc32b2405b" },
            .javascript => .{ .repo = "tree-sitter/tree-sitter-javascript", .commit = "58404d8cf191d69f2674a8fd507bd5776f46cb11", .sha256 = "f3e51e9f7b129f62a817551ae22a878dac5c18d71c456d5ad73e9c82d687f33d" },
            .typescript => .{ .repo = "tree-sitter/tree-sitter-typescript", .commit = "75b3874edb2dc714fb1fd77a32013d0f8699989f", .sha256 = "96ce4d1b513767d414bcca408efd9b49879162cceecdbed79a88e8ad2184f385" },
            .bash => .{ .repo = "tree-sitter/tree-sitter-bash", .commit = "a06c2e4415e9bc0346c6b86d401879ffb44058f7", .sha256 = "879e8951ea2cc82455407e3eda0293319657ec53e83191e0fb5a67430d10d804" },
            .go => .{ .repo = "tree-sitter/tree-sitter-go", .commit = "2346a3ab1bb3857b48b29d779a1ef9799a248cd7", .sha256 = "94d08fc0f727a8dbe03203e2aaf1c5dc33a57e496b583049324eddc79769797b" },
            .html => .{ .repo = "tree-sitter/tree-sitter-html", .commit = "73a3947324f6efddf9e17c0ea58d454843590cc0", .sha256 = "892f6b732e08bcb90918a985fdee58d6a0fd7a90326af601a2536a5d477583fa" },
            .css => .{ .repo = "tree-sitter/tree-sitter-css", .commit = "dda5cfc5722c429eaba1c910ca32c2c0c5bb1a3f", .sha256 = "c47392e483feb9137d8f0acf9ca6e916b820122c260324454a9980c75c98c3c5" },
            .toml => .{ .repo = "tree-sitter-grammars/tree-sitter-toml", .commit = "64b56832c2cffe41758f28e05c756a3a98d16f41", .sha256 = "feeb2e1cf531588cdcfb9c57292620151a08597f18a98dad26cc17fd4b544dcb" },
            .yaml => .{ .repo = "tree-sitter-grammars/tree-sitter-yaml", .commit = "a1c4812a73ec5e089de8e441fdea3a921e8d5079", .sha256 = "6548cd059983e8073dfa39f102641f71d045b37f3a05b7ebd799ad17df8471d1" },
            .lua => .{ .repo = "tree-sitter-grammars/tree-sitter-lua", .commit = "10fe0054734eec83049514ea2e718b2a56acd0c9", .sha256 = "82c3ca5808de02addd9c7fb5275d89260c6557019aa6e40ca52c0595bf1d33cd" },
            .make => .{ .repo = "tree-sitter-grammars/tree-sitter-make", .commit = "70613f3d812cbabbd7f38d104d60a409c4008b43", .sha256 = "bd60f6d2950086ba5d1d81e0890fc3e4e71e4d276b58b8cc1e1e95c9609ce331" },
            .java => .{ .repo = "tree-sitter/tree-sitter-java", .commit = "e10607b45ff745f5f876bfa3e94fbcc6b44bdc11", .sha256 = "95a46b6b7b545b48cd6c3a0d5b1014fed271a63a71164cdc4382d9d441e3609f" },
            .diff => .{ .repo = "tree-sitter-grammars/tree-sitter-diff", .commit = "ada384ac7bfc1307f32de474620120add29998fb", .sha256 = "e11ccb2f6a5bd966170ccba7d160d832e002e64006a101d7339137795158e73b" },
            .xml => .{ .repo = "tree-sitter-grammars/tree-sitter-xml", .commit = "5000ae8f22d11fbe93939b05c1e37cf21117162d", .sha256 = "1b7611ba3f2af55768acfbfbaf2fd2eb404ba61b14a85056d4f8d8326fc55146" },
            .dockerfile => .{ .repo = "camdencheek/tree-sitter-dockerfile", .commit = "971acdd908568b4531b0ba28a445bf0bb720aba5", .sha256 = "0263fd719ce93ea663847a49b501052c2b93853e33ffc5e8ddca3a739d7db246" },
        };
    }
};

pub const Grammar = enum {
    zig,
    c,
    cpp,
    json,
    markdown,
    markdown_inline,
    python,
    rust,
    javascript,
    typescript,
    tsx,
    bash,
    go,
    html,
    css,
    toml,
    yaml,
    lua,
    make,
    java,
    diff,
    xml,
    dockerfile,

    pub fn upstream(self: Grammar) Upstream {
        return switch (self) {
            .markdown_inline => .markdown,
            .tsx => .typescript,
            inline else => |g| @field(Upstream, @tagName(g)),
        };
    }

    /// The directory inside the upstream tree holding `parser.c`, its
    /// `tree_sitter/` ABI headers and any `scanner.c`.
    ///
    /// Monorepo layouts are kept as upstream ships them: the typescript,
    /// tsx and xml scanners include `../../common/scanner.h`.
    pub fn srcDir(self: Grammar) []const u8 {
        return switch (self) {
            .markdown => "tree-sitter-markdown/src",
            .markdown_inline => "tree-sitter-markdown-inline/src",
            .typescript => "typescript/src",
            .tsx => "tsx/src",
            .xml => "xml/src",
            else => "src",
        };
    }

    /// Whether the grammar ships an external scanner (`scanner.c`).
    pub fn hasScanner(self: Grammar) bool {
        return switch (self) {
            .zig, .c, .json, .go, .make, .java, .diff => false,
            .cpp, .markdown, .markdown_inline, .python, .rust, .javascript, .typescript, .tsx, .bash, .html, .css, .toml, .yaml, .lua, .xml, .dockerfile => true,
        };
    }

    /// Highlight queries, concatenated in order into one query.
    ///
    /// Order is general-to-specific because the highlighter paints the
    /// LATER of two equal-range patterns on top: C++ refines C's query
    /// (upstream's `; inherits: c`), TypeScript refines JavaScript's.
    pub fn queries(self: Grammar) []const Query {
        return switch (self) {
            .cpp => &.{ .c, .cpp },
            .javascript => &.{ .javascript, .javascript_jsx, .javascript_params },
            .typescript => &.{ .javascript, .typescript },
            .tsx => &.{ .javascript, .javascript_jsx, .typescript },
            inline else => |g| &.{@field(Query, @tagName(g))},
        };
    }
};

/// One upstream highlight query file. Where upstream splits a
/// language's highlighting over several files each is its own member.
pub const Query = enum {
    zig,
    c,
    cpp,
    json,
    markdown,
    markdown_inline,
    python,
    rust,
    javascript,
    javascript_jsx,
    javascript_params,
    typescript,
    bash,
    go,
    html,
    css,
    toml,
    yaml,
    lua,
    make,
    java,
    diff,
    xml,
    dockerfile,

    pub const Source = struct { upstream: Upstream, path: []const u8 };

    pub fn source(self: Query) Source {
        return switch (self) {
            .markdown => .{ .upstream = .markdown, .path = "tree-sitter-markdown/queries/highlights.scm" },
            .markdown_inline => .{ .upstream = .markdown, .path = "tree-sitter-markdown-inline/queries/highlights.scm" },
            .javascript_jsx => .{ .upstream = .javascript, .path = "queries/highlights-jsx.scm" },
            .javascript_params => .{ .upstream = .javascript, .path = "queries/highlights-params.scm" },
            .xml => .{ .upstream = .xml, .path = "queries/xml/highlights.scm" },
            inline else => |q| .{ .upstream = @field(Upstream, @tagName(q)), .path = "queries/highlights.scm" },
        };
    }
};

pub const COUNT: usize = @typeInfo(Grammar).@"enum".fields.len;

test "grammars: every query and every upstream is used by some grammar" {
    for (std.enums.values(Query)) |q| {
        var used = false;
        for (std.enums.values(Grammar)) |g| {
            for (g.queries()) |gq| {
                if (gq == q) used = true;
            }
        }
        try std.testing.expect(used);
    }
    for (std.enums.values(Upstream)) |u| {
        var used = false;
        for (std.enums.values(Grammar)) |g| {
            if (g.upstream() == u) used = true;
        }
        try std.testing.expect(used);
    }
}

test "grammars: pins are full commit ids and SHA-256 digests" {
    for (std.enums.values(Upstream)) |u| {
        const p = u.pin();
        try std.testing.expectEqual(@as(usize, 40), p.commit.len);
        try std.testing.expectEqual(@as(usize, 64), p.sha256.len);
    }
}
