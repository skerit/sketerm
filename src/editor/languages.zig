//! The editor's language registry: ONE declaring row per language.
//!
//! Everything language-specific in the editor derives from a row here:
//! file detection (name, extension, shebang, head sniffing), the
//! toggle-comment tokens, the LSP `languageId`, the lexical rules the
//! grammar-less bracket matcher and fold producer use
//! (`editor/lexical.zig`), the fold fallback, the tab policy the
//! indentation resolver consults, and the Tree-sitter grammars that
//! highlight it (`editor/syntax.zig`). Adding a language is adding a
//! row; `specs` is an `EnumArray` initialised with every member named,
//! so a member without a row does not compile.
//!
//! Pure data plus string matching, std-only: `lsp/servers.zig` reads it
//! for `languageId`, and that module is compiled into `sketerm-mux`, so
//! nothing here may reach Tree-sitter, GTK or libc. `grammars.zig` is
//! the one grammar vocabulary and is equally pure.

const std = @import("std");
pub const Grammar = @import("grammars.zig").Grammar;

// ======================================================================
// Row types
// ======================================================================

pub const Delims = struct { open: []const u8, close: []const u8 };

pub const Comments = struct {
    /// Line-comment tokens; the FIRST is what toggle-comment writes.
    line: []const []const u8 = &.{},
    block: ?Delims = null,
    /// `/* /* */ */` is one comment (Rust, Swift, Kotlin, Haskell).
    nested: bool = false,
    /// A line comment only starts at a word boundary, so shell's `$#`
    /// and YAML's `a#b` are code.
    line_needs_boundary: bool = false,
};

/// One string or character literal form, for the lexical fallback.
pub const StringRule = struct {
    open: []const u8,
    close: []const u8,
    escape: ?u8 = '\\',
    multiline: bool = false,
    /// Longest unescaped body in bytes (an escaped one may run to a
    /// `\u{...}` sequence); an opener that does not close within it on
    /// the same line is not a literal at all (a Rust lifetime `'a`).
    max_len: ?u16 = null,
    /// Whether the opener may directly follow a word byte: Python's
    /// `f"..."` needs it, an apostrophe in YAML's `don't` must not.
    after_word: bool = true,
};

/// What folding falls back to when there is no syntax tree.
pub const Fold = enum { brackets, indent };

/// How strongly a language wants hard tabs (see `editor/indentation.zig`
/// for where each level sits in the precedence).
pub const TabPolicy = enum {
    none,
    /// The ecosystem's formatter writes tabs (gofmt).
    prefer,
    /// Spaces are a syntax error where it matters (Makefile recipes).
    require,
};

/// Extension that is ambiguous between languages, claimed by this one
/// when the document head carries any of `markers` (`.h` as C++).
pub const Claim = struct {
    ext: []const u8,
    markers: []const []const u8,
};

pub const Spec = struct {
    /// Display name ("C++").
    name: []const u8,
    /// LSP `languageId`; empty = no server is ever asked.
    lsp_id: []const u8 = "",
    /// Case-insensitive, without the dot.
    extensions: []const []const u8 = &.{},
    /// Case-insensitive whole basenames; one `*` may stand for any run
    /// of bytes (`Dockerfile.*`).
    filenames: []const []const u8 = &.{},
    /// Shebang interpreter basenames; a version suffix of digits and
    /// dots is accepted (`python3.12` matches `python`).
    interpreters: []const []const u8 = &.{},
    /// First-line prefixes that identify an otherwise unknown file.
    magic: []const []const u8 = &.{},
    claims: ?Claim = null,
    comments: Comments = .{},
    strings: []const StringRule = &.{},
    /// Highlight layers, painted in order; empty = no grammar.
    grammars: []const Grammar = &.{},
    fold: Fold = .brackets,
    tabs: TabPolicy = .none,
};

// ======================================================================
// Shared rule sets (so a family's lexical facts are written once)
// ======================================================================

const C_COMMENTS = Comments{ .line = &.{"//"}, .block = .{ .open = "/*", .close = "*/" } };
const C_COMMENTS_NESTED = Comments{ .line = &.{"//"}, .block = .{ .open = "/*", .close = "*/" }, .nested = true };
const HASH_COMMENTS = Comments{ .line = &.{"#"} };
const SHELL_COMMENTS = Comments{ .line = &.{"#"}, .line_needs_boundary = true };
const MARKUP_COMMENTS = Comments{ .block = .{ .open = "<!--", .close = "-->" } };
const SEMI_COMMENTS = Comments{ .line = &.{";"} };

const DQ = StringRule{ .open = "\"", .close = "\"" };
const DQ_ML = StringRule{ .open = "\"", .close = "\"", .multiline = true };
const SQ = StringRule{ .open = "'", .close = "'" };
const SQ_RAW_ML = StringRule{ .open = "'", .close = "'", .escape = null, .multiline = true };
/// A C-family character literal: one UTF-8 character or an escape, so
/// a `'` in odd places cannot swallow the rest of the line.
const CHAR = StringRule{ .open = "'", .close = "'", .max_len = 4 };
const BACKTICK_ML = StringRule{ .open = "`", .close = "`", .multiline = true };
const BACKTICK_RAW_ML = StringRule{ .open = "`", .close = "`", .escape = null, .multiline = true };
const TRIPLE_DQ = StringRule{ .open = "\"\"\"", .close = "\"\"\"", .multiline = true };
const TRIPLE_SQ = StringRule{ .open = "'''", .close = "'''", .multiline = true };
/// Quotes that only open away from a word: prose-ish formats, where
/// `don't` is an apostrophe.
const DQ_WORD = StringRule{ .open = "\"", .close = "\"", .after_word = false };
const SQ_WORD = StringRule{ .open = "'", .close = "'", .escape = null, .after_word = false };

const C_STRINGS = [_]StringRule{ DQ, CHAR };
const JS_STRINGS = [_]StringRule{ DQ, SQ, BACKTICK_ML };
const PY_STRINGS = [_]StringRule{ TRIPLE_DQ, TRIPLE_SQ, DQ, SQ };
const SHELL_STRINGS = [_]StringRule{ DQ_ML, SQ_RAW_ML };

// ======================================================================
// The registry
// ======================================================================

pub const Lang = enum {
    zig,
    c,
    cpp,
    cuda,
    objective_c,
    objective_cpp,
    json,
    jsonc,
    markdown,
    python,
    rust,
    javascript,
    javascriptreact,
    typescript,
    typescriptreact,
    shell,
    go,
    html,
    css,
    scss,
    less,
    toml,
    yaml,
    lua,
    make,
    java,
    diff,
    xml,
    dockerfile,
    ruby,
    php,
    csharp,
    kotlin,
    swift,
    scala,
    dart,
    groovy,
    haskell,
    ocaml,
    elixir,
    erlang,
    clojure,
    lisp,
    perl,
    r,
    julia,
    sql,
    nix,
    hcl,
    cmake,
    ini,
    properties,
    powershell,
    fish,
    awk,
    protobuf,
    graphql,
    latex,
    glsl,
    git_commit,
    git_rebase,
    gitignore,

    pub fn spec(self: Lang) *const Spec {
        return specs.getPtrConst(self);
    }

    pub fn displayName(self: Lang) []const u8 {
        return self.spec().name;
    }

    /// Token toggle-comment writes at the start of a line, if any.
    pub fn lineComment(self: Lang) ?[]const u8 {
        const l = self.spec().comments.line;
        return if (l.len > 0) l[0] else null;
    }

    pub fn blockComment(self: Lang) ?Delims {
        return self.spec().comments.block;
    }

    /// LSP `languageId`, empty when no server should be asked.
    pub fn lspId(self: Lang) []const u8 {
        return self.spec().lsp_id;
    }

    pub fn grammars(self: Lang) []const Grammar {
        return self.spec().grammars;
    }

    pub fn hasGrammar(self: Lang) bool {
        return self.spec().grammars.len > 0;
    }
};

pub const specs = std.enums.EnumArray(Lang, Spec).init(.{
    .zig = .{
        .name = "Zig",
        .lsp_id = "zig",
        .extensions = &.{ "zig", "zon" },
        .interpreters = &.{"zig"},
        .comments = .{ .line = &.{"//"} },
        // Multiline string lines start with `\\` and run to the end of
        // the line, which is exactly a line comment to the lexer.
        .strings = &.{ DQ, CHAR, .{ .open = "\\\\", .close = "\n", .escape = null } },
        .grammars = &.{.zig},
    },
    .c = .{
        .name = "C",
        .lsp_id = "c",
        .extensions = &.{ "c", "h" },
        .interpreters = &.{"tcc"},
        .comments = C_COMMENTS,
        .strings = &C_STRINGS,
        .grammars = &.{.c},
    },
    .cpp = .{
        .name = "C++",
        .lsp_id = "cpp",
        .extensions = &.{ "cc", "cpp", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp", "tpp", "inl", "ixx", "cppm" },
        // `.h` is C unless the head reads as C++; a C header full of
        // `#ifdef __cplusplus` guards is still C, so that is no marker.
        .claims = .{ .ext = "h", .markers = &.{
            "class ",       "namespace ",   "template <",       "template<",
            "public:",      "private:",     "protected:",       "std::",
            "#include <iostream>", "#include <string>", "#include <vector>", "#include <memory>",
            "constexpr ",   "nullptr",      "virtual ",         "typename ",
        } },
        .comments = C_COMMENTS,
        .strings = &C_STRINGS,
        .grammars = &.{.cpp},
    },
    .cuda = .{
        .name = "CUDA",
        .lsp_id = "cuda",
        .extensions = &.{ "cu", "cuh" },
        .comments = C_COMMENTS,
        .strings = &C_STRINGS,
        .grammars = &.{.cpp},
    },
    .objective_c = .{
        .name = "Objective-C",
        .lsp_id = "objective-c",
        .extensions = &.{"m"},
        .comments = C_COMMENTS,
        .strings = &C_STRINGS,
    },
    .objective_cpp = .{
        .name = "Objective-C++",
        .lsp_id = "objective-cpp",
        .extensions = &.{"mm"},
        .comments = C_COMMENTS,
        .strings = &C_STRINGS,
    },
    .json = .{
        .name = "JSON",
        .lsp_id = "json",
        .extensions = &.{ "json", "geojson", "webmanifest" },
        .filenames = &.{ ".babelrc", ".watchmanconfig", "composer.lock", "flake.lock" },
        .strings = &.{DQ},
        .grammars = &.{.json},
    },
    .jsonc = .{
        .name = "JSON with Comments",
        .lsp_id = "jsonc",
        .extensions = &.{ "jsonc", "json5" },
        .filenames = &.{ "tsconfig.json", "jsconfig.json", "tsconfig.*.json", ".eslintrc.json", "devcontainer.json", ".devcontainer.json" },
        .comments = C_COMMENTS,
        .strings = &.{ DQ, SQ },
        .grammars = &.{.json},
    },
    .markdown = .{
        .name = "Markdown",
        .lsp_id = "markdown",
        .extensions = &.{ "md", "markdown", "mdown", "mkd", "mkdn" },
        .filenames = &.{"README"},
        .comments = MARKUP_COMMENTS,
        .grammars = &.{ .markdown, .markdown_inline },
        .fold = .indent,
    },
    .python = .{
        .name = "Python",
        .lsp_id = "python",
        .extensions = &.{ "py", "pyi", "pyw", "pyx", "pxd" },
        .filenames = &.{ "SConstruct", "SConscript", "wscript" },
        .interpreters = &.{ "python", "pypy", "python2", "python3" },
        .comments = HASH_COMMENTS,
        .strings = &PY_STRINGS,
        .grammars = &.{.python},
        .fold = .indent,
    },
    .rust = .{
        .name = "Rust",
        .lsp_id = "rust",
        .extensions = &.{"rs"},
        .interpreters = &.{"run-cargo-script"},
        .comments = C_COMMENTS_NESTED,
        // A `'` that does not close within a char literal's length is a
        // lifetime or a label, never a string.
        .strings = &.{ DQ_ML, CHAR },
        .grammars = &.{.rust},
    },
    .javascript = .{
        .name = "JavaScript",
        .lsp_id = "javascript",
        .extensions = &.{ "js", "mjs", "cjs" },
        .interpreters = &.{ "node", "nodejs", "bun", "qjs" },
        .comments = C_COMMENTS,
        .strings = &JS_STRINGS,
        .grammars = &.{.javascript},
    },
    .javascriptreact = .{
        .name = "JavaScript React",
        .lsp_id = "javascriptreact",
        .extensions = &.{"jsx"},
        .comments = C_COMMENTS,
        .strings = &JS_STRINGS,
        .grammars = &.{.javascript},
    },
    .typescript = .{
        .name = "TypeScript",
        .lsp_id = "typescript",
        .extensions = &.{ "ts", "mts", "cts" },
        .interpreters = &.{ "deno", "ts-node", "tsx" },
        .comments = C_COMMENTS,
        .strings = &JS_STRINGS,
        .grammars = &.{.typescript},
    },
    .typescriptreact = .{
        .name = "TypeScript React",
        .lsp_id = "typescriptreact",
        .extensions = &.{"tsx"},
        .comments = C_COMMENTS,
        .strings = &JS_STRINGS,
        .grammars = &.{.tsx},
    },
    .shell = .{
        .name = "Shell",
        .lsp_id = "shellscript",
        .extensions = &.{ "sh", "bash", "zsh", "ksh", "ebuild", "eclass", "bats" },
        .filenames = &.{
            ".bashrc",     ".bash_profile", ".bash_logout", ".bash_aliases", ".profile",
            ".zshrc",      ".zshenv",       ".zprofile",    ".zlogin",       ".zlogout",
            ".kshrc",      ".envrc",        "PKGBUILD",     "APKBUILD",      "*.install",
        },
        .interpreters = &.{ "sh", "bash", "zsh", "ksh", "dash", "ash", "mksh", "busybox" },
        .comments = SHELL_COMMENTS,
        .strings = &SHELL_STRINGS,
        .grammars = &.{.bash},
    },
    .go = .{
        .name = "Go",
        .lsp_id = "go",
        .extensions = &.{"go"},
        .comments = C_COMMENTS,
        .strings = &.{ DQ, CHAR, BACKTICK_RAW_ML },
        .grammars = &.{.go},
        .tabs = .prefer,
    },
    .html = .{
        .name = "HTML",
        .lsp_id = "html",
        .extensions = &.{ "html", "htm", "xhtml", "shtml" },
        .magic = &.{ "<!DOCTYPE html", "<!doctype html", "<html" },
        .comments = MARKUP_COMMENTS,
        .grammars = &.{.html},
    },
    .css = .{
        .name = "CSS",
        .lsp_id = "css",
        .extensions = &.{"css"},
        .comments = .{ .block = .{ .open = "/*", .close = "*/" } },
        .strings = &.{ DQ, SQ },
        .grammars = &.{.css},
    },
    .scss = .{
        .name = "SCSS",
        .lsp_id = "scss",
        .extensions = &.{ "scss", "sass" },
        .comments = C_COMMENTS,
        .strings = &.{ DQ, SQ },
    },
    .less = .{
        .name = "Less",
        .lsp_id = "less",
        .extensions = &.{"less"},
        .comments = C_COMMENTS,
        .strings = &.{ DQ, SQ },
    },
    .toml = .{
        .name = "TOML",
        .lsp_id = "toml",
        .extensions = &.{"toml"},
        .filenames = &.{ "Cargo.lock", "Pipfile", "poetry.lock", "uv.lock" },
        .comments = HASH_COMMENTS,
        .strings = &.{ TRIPLE_DQ, .{ .open = "'''", .close = "'''", .escape = null, .multiline = true }, DQ, .{ .open = "'", .close = "'", .escape = null } },
        .grammars = &.{.toml},
    },
    .yaml = .{
        .name = "YAML",
        .lsp_id = "yaml",
        .extensions = &.{ "yaml", "yml" },
        .filenames = &.{ ".clang-format", ".clang-tidy", ".clangd" },
        .comments = SHELL_COMMENTS,
        .strings = &.{ DQ_WORD, SQ_WORD },
        .grammars = &.{.yaml},
        .fold = .indent,
    },
    .lua = .{
        .name = "Lua",
        .lsp_id = "lua",
        .extensions = &.{ "lua", "rockspec", "luau" },
        .interpreters = &.{ "lua", "luajit" },
        .comments = .{ .line = &.{"--"}, .block = .{ .open = "--[[", .close = "]]" } },
        .strings = &.{ DQ, SQ, .{ .open = "[[", .close = "]]", .escape = null, .multiline = true } },
        .grammars = &.{.lua},
    },
    .make = .{
        .name = "Makefile",
        .lsp_id = "makefile",
        .extensions = &.{ "mk", "mak", "make" },
        .filenames = &.{ "Makefile", "makefile", "GNUmakefile", "BSDmakefile", "Makefile.*", "Kbuild" },
        .interpreters = &.{ "make", "gmake" },
        .comments = SHELL_COMMENTS,
        .grammars = &.{.make},
        .tabs = .require,
    },
    .java = .{
        .name = "Java",
        .lsp_id = "java",
        .extensions = &.{"java"},
        .comments = C_COMMENTS,
        .strings = &.{ TRIPLE_DQ, DQ, CHAR },
        .grammars = &.{.java},
    },
    .diff = .{
        .name = "Diff",
        .lsp_id = "diff",
        .extensions = &.{ "diff", "patch", "rej" },
        .magic = &.{ "diff --git ", "--- a/" },
        .grammars = &.{.diff},
        .fold = .indent,
    },
    .xml = .{
        .name = "XML",
        .lsp_id = "xml",
        .extensions = &.{
            "xml",     "svg",    "xsd",    "xsl",   "xslt",    "rng",   "plist", "xaml",
            "csproj",  "fsproj", "vbproj", "vcxproj", "props", "targets", "gpx", "kml",
            "xliff",   "xlf",    "rss",    "atom",  "wsdl",    "glade", "ui",
        },
        .magic = &.{"<?xml"},
        .comments = MARKUP_COMMENTS,
        .grammars = &.{.xml},
    },
    .dockerfile = .{
        .name = "Dockerfile",
        .lsp_id = "dockerfile",
        .extensions = &.{ "dockerfile", "containerfile" },
        .filenames = &.{ "Dockerfile", "Containerfile", "Dockerfile.*", "Containerfile.*" },
        .comments = HASH_COMMENTS,
        .strings = &.{ DQ, SQ },
        .grammars = &.{.dockerfile},
    },
    .ruby = .{
        .name = "Ruby",
        .lsp_id = "ruby",
        .extensions = &.{ "rb", "rake", "gemspec", "ru", "erb" },
        .filenames = &.{ "Rakefile", "Gemfile", "Guardfile", "Vagrantfile", "Brewfile", "Podfile", "Fastfile" },
        .interpreters = &.{ "ruby", "jruby" },
        .comments = HASH_COMMENTS,
        .strings = &.{ DQ_ML, .{ .open = "'", .close = "'", .multiline = true }, BACKTICK_ML },
    },
    .php = .{
        .name = "PHP",
        .lsp_id = "php",
        .extensions = &.{ "php", "phtml", "php3", "php4", "php5", "phps" },
        .interpreters = &.{"php"},
        .magic = &.{"<?php"},
        .comments = .{ .line = &.{ "//", "#" }, .block = .{ .open = "/*", .close = "*/" } },
        .strings = &.{ DQ_ML, .{ .open = "'", .close = "'", .multiline = true }, BACKTICK_ML },
    },
    .csharp = .{
        .name = "C#",
        .lsp_id = "csharp",
        .extensions = &.{ "cs", "csx" },
        .comments = C_COMMENTS,
        .strings = &.{ TRIPLE_DQ, DQ, CHAR },
    },
    .kotlin = .{
        .name = "Kotlin",
        .lsp_id = "kotlin",
        .extensions = &.{ "kt", "kts" },
        .comments = C_COMMENTS_NESTED,
        .strings = &.{ TRIPLE_DQ, DQ, CHAR },
    },
    .swift = .{
        .name = "Swift",
        .lsp_id = "swift",
        .extensions = &.{"swift"},
        .comments = C_COMMENTS_NESTED,
        .strings = &.{ TRIPLE_DQ, DQ },
    },
    .scala = .{
        .name = "Scala",
        .lsp_id = "scala",
        .extensions = &.{ "scala", "sc", "sbt" },
        .comments = C_COMMENTS_NESTED,
        .strings = &.{ TRIPLE_DQ, DQ, CHAR },
    },
    .dart = .{
        .name = "Dart",
        .lsp_id = "dart",
        .extensions = &.{"dart"},
        .comments = C_COMMENTS_NESTED,
        .strings = &.{ TRIPLE_DQ, TRIPLE_SQ, DQ, SQ },
    },
    .groovy = .{
        .name = "Groovy",
        .lsp_id = "groovy",
        .extensions = &.{ "groovy", "gradle", "gvy" },
        .filenames = &.{"Jenkinsfile"},
        .interpreters = &.{"groovy"},
        .comments = C_COMMENTS,
        .strings = &.{ TRIPLE_DQ, TRIPLE_SQ, DQ, SQ },
    },
    .haskell = .{
        .name = "Haskell",
        .lsp_id = "haskell",
        .extensions = &.{ "hs", "hsc" },
        .interpreters = &.{ "runhaskell", "runghc" },
        .comments = .{ .line = &.{"--"}, .block = .{ .open = "{-", .close = "-}" }, .nested = true },
        .strings = &.{DQ},
        .fold = .indent,
    },
    .ocaml = .{
        .name = "OCaml",
        .lsp_id = "ocaml",
        .extensions = &.{ "ml", "mli" },
        .interpreters = &.{"ocaml"},
        .comments = .{ .block = .{ .open = "(*", .close = "*)" }, .nested = true },
        .strings = &.{DQ_ML},
    },
    .elixir = .{
        .name = "Elixir",
        .lsp_id = "elixir",
        .extensions = &.{ "ex", "exs" },
        .interpreters = &.{"elixir"},
        .comments = HASH_COMMENTS,
        .strings = &.{ TRIPLE_DQ, DQ_ML },
    },
    .erlang = .{
        .name = "Erlang",
        .lsp_id = "erlang",
        .extensions = &.{ "erl", "hrl" },
        .filenames = &.{"rebar.config"},
        .interpreters = &.{"escript"},
        .comments = .{ .line = &.{"%"} },
        .strings = &.{DQ_ML},
    },
    .clojure = .{
        .name = "Clojure",
        .lsp_id = "clojure",
        .extensions = &.{ "clj", "cljs", "cljc", "edn" },
        .interpreters = &.{ "clojure", "bb" },
        .comments = SEMI_COMMENTS,
        .strings = &.{DQ_ML},
    },
    .lisp = .{
        .name = "Lisp",
        .lsp_id = "lisp",
        .extensions = &.{ "lisp", "lsp", "el", "scm", "ss", "rkt", "fnl" },
        .filenames = &.{ ".emacs", "_emacs" },
        .interpreters = &.{ "sbcl", "guile", "racket", "emacs" },
        .comments = SEMI_COMMENTS,
        .strings = &.{DQ_ML},
    },
    .perl = .{
        .name = "Perl",
        .lsp_id = "perl",
        .extensions = &.{ "pl", "pm", "t", "pod" },
        .interpreters = &.{"perl"},
        .comments = SHELL_COMMENTS,
        .strings = &.{ DQ_ML, .{ .open = "'", .close = "'", .multiline = true } },
    },
    .r = .{
        .name = "R",
        .lsp_id = "r",
        .extensions = &.{ "r", "rmd" },
        .filenames = &.{".Rprofile"},
        .interpreters = &.{"Rscript"},
        .comments = HASH_COMMENTS,
        .strings = &.{ DQ_ML, .{ .open = "'", .close = "'", .multiline = true } },
    },
    .julia = .{
        .name = "Julia",
        .lsp_id = "julia",
        .extensions = &.{"jl"},
        .interpreters = &.{"julia"},
        .comments = .{ .line = &.{"#"}, .block = .{ .open = "#=", .close = "=#" }, .nested = true },
        .strings = &.{ TRIPLE_DQ, DQ, CHAR },
    },
    .sql = .{
        .name = "SQL",
        .lsp_id = "sql",
        .extensions = &.{ "sql", "psql", "pgsql", "mysql", "ddl" },
        .comments = .{ .line = &.{"--"}, .block = .{ .open = "/*", .close = "*/" } },
        .strings = &.{ .{ .open = "'", .close = "'", .escape = null, .multiline = true }, .{ .open = "\"", .close = "\"", .escape = null } },
    },
    .nix = .{
        .name = "Nix",
        .lsp_id = "nix",
        .extensions = &.{"nix"},
        .comments = .{ .line = &.{"#"}, .block = .{ .open = "/*", .close = "*/" } },
        .strings = &.{ .{ .open = "''", .close = "''", .escape = null, .multiline = true }, DQ_ML },
    },
    .hcl = .{
        .name = "HCL",
        .lsp_id = "terraform",
        .extensions = &.{ "tf", "tfvars", "hcl", "nomad" },
        .comments = .{ .line = &.{ "#", "//" }, .block = .{ .open = "/*", .close = "*/" } },
        .strings = &.{DQ},
    },
    .cmake = .{
        .name = "CMake",
        .lsp_id = "cmake",
        .extensions = &.{"cmake"},
        .filenames = &.{"CMakeLists.txt"},
        .comments = .{ .line = &.{"#"}, .block = .{ .open = "#[[", .close = "]]" } },
        .strings = &.{DQ_ML},
    },
    .ini = .{
        .name = "INI",
        .lsp_id = "ini",
        .extensions = &.{ "ini", "cfg", "conf", "cnf", "desktop", "service", "socket", "timer", "mount", "automount", "slice", "target", "network", "netdev", "link", "container", "flatpakref", "inf", "reg" },
        .filenames = &.{ ".editorconfig", ".gitconfig", ".gitmodules", "config", ".npmrc", ".pylintrc", "setup.cfg", "tox.ini", "pytest.ini", "mypy.ini" },
        .comments = .{ .line = &.{ "#", ";" } },
        .fold = .indent,
    },
    .properties = .{
        .name = "Properties",
        .lsp_id = "properties",
        .extensions = &.{ "properties", "env" },
        .filenames = &.{ ".env", ".env.*" },
        .comments = .{ .line = &.{ "#", "!" } },
        .fold = .indent,
    },
    .powershell = .{
        .name = "PowerShell",
        .lsp_id = "powershell",
        .extensions = &.{ "ps1", "psm1", "psd1" },
        .interpreters = &.{ "pwsh", "powershell" },
        .comments = .{ .line = &.{"#"}, .block = .{ .open = "<#", .close = "#>" } },
        .strings = &.{ .{ .open = "\"", .close = "\"", .escape = '`', .multiline = true }, .{ .open = "'", .close = "'", .escape = null, .multiline = true } },
    },
    .fish = .{
        .name = "Fish",
        .lsp_id = "fish",
        .extensions = &.{"fish"},
        .interpreters = &.{"fish"},
        .comments = SHELL_COMMENTS,
        .strings = &SHELL_STRINGS,
    },
    .awk = .{
        .name = "AWK",
        .lsp_id = "awk",
        .extensions = &.{ "awk", "gawk" },
        .interpreters = &.{ "awk", "gawk", "mawk", "nawk" },
        .comments = HASH_COMMENTS,
        .strings = &.{DQ},
    },
    .protobuf = .{
        .name = "Protocol Buffers",
        .lsp_id = "proto",
        .extensions = &.{"proto"},
        .comments = C_COMMENTS,
        .strings = &.{ DQ, SQ },
    },
    .graphql = .{
        .name = "GraphQL",
        .lsp_id = "graphql",
        .extensions = &.{ "graphql", "gql", "graphqls" },
        .comments = HASH_COMMENTS,
        .strings = &.{ TRIPLE_DQ, DQ },
    },
    .latex = .{
        .name = "LaTeX",
        .lsp_id = "latex",
        .extensions = &.{ "tex", "sty", "cls", "ltx", "bib" },
        .comments = .{ .line = &.{"%"} },
    },
    .glsl = .{
        .name = "GLSL",
        .lsp_id = "glsl",
        .extensions = &.{ "glsl", "vert", "frag", "geom", "comp", "tesc", "tese", "hlsl", "wgsl", "metal" },
        .comments = C_COMMENTS,
        .strings = &.{DQ},
    },
    .git_commit = .{
        .name = "Git Commit Message",
        .lsp_id = "git-commit",
        .filenames = &.{ "COMMIT_EDITMSG", "MERGE_MSG", "TAG_EDITMSG", "SQUASH_MSG", "NOTES_EDITMSG", "EDIT_DESCRIPTION" },
        .comments = .{ .line = &.{"#"} },
        .fold = .indent,
    },
    .git_rebase = .{
        .name = "Git Rebase Todo",
        .lsp_id = "git-rebase",
        .filenames = &.{"git-rebase-todo"},
        .comments = .{ .line = &.{"#"} },
        .fold = .indent,
    },
    .gitignore = .{
        .name = "Ignore List",
        .lsp_id = "ignore",
        .filenames = &.{ ".gitignore", ".dockerignore", ".npmignore", ".hgignore", ".ignore", ".rgignore", ".fdignore", ".gitattributes", ".prettierignore", ".eslintignore" },
        .comments = .{ .line = &.{"#"} },
        .fold = .indent,
    },
});

// ======================================================================
// Detection
// ======================================================================

/// Last path component. A host-qualified spec (`box:/etc/x`) and a
/// Windows-ish path both reduce correctly, independent of the host
/// separator.
pub fn basenameOf(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\' or ch == ':') start = i + 1;
    }
    return path[start..];
}

/// Case-insensitive match of `name` against a pattern with at most one
/// `*` standing for any (possibly empty) run of bytes.
fn nameMatches(pattern: []const u8, name: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.ascii.eqlIgnoreCase(pattern, name);
    const pre = pattern[0..star];
    const post = pattern[star + 1 ..];
    if (name.len < pre.len + post.len) return false;
    return std.ascii.startsWithIgnoreCase(name, pre) and std.ascii.endsWithIgnoreCase(name, post);
}

fn extensionOf(base: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    // A leading-dot name (".bashrc") has no extension.
    if (dot == 0) return null;
    const ext = base[dot + 1 ..];
    return if (ext.len == 0) null else ext;
}

fn hasExt(spec: *const Spec, ext: []const u8) bool {
    for (spec.extensions) |e| {
        if (std.ascii.eqlIgnoreCase(e, ext)) return true;
    }
    return false;
}

/// Whether `head` carries any of `markers` (a plain substring scan; the
/// markers are chosen to be implausible outside the claiming language).
fn headHasMarker(head: []const u8, markers: []const []const u8) bool {
    for (markers) |m| {
        if (std.mem.indexOf(u8, head, m) != null) return true;
    }
    return false;
}

/// Language for a path by name and extension alone. `head` (any prefix
/// of the document, possibly empty) settles ambiguous extensions.
pub fn detectFromPathHead(path: []const u8, head: []const u8) ?Lang {
    const base = basenameOf(path);
    if (base.len == 0) return null;
    // Exact names beat patterns beat extensions: `tsconfig.json` is
    // JSONC although `.json` is JSON, `Makefile.am` is a Makefile.
    for (std.enums.values(Lang)) |l| {
        for (l.spec().filenames) |f| {
            if (std.mem.indexOfScalar(u8, f, '*') == null and std.ascii.eqlIgnoreCase(f, base)) return l;
        }
    }
    for (std.enums.values(Lang)) |l| {
        for (l.spec().filenames) |f| {
            if (std.mem.indexOfScalar(u8, f, '*') != null and nameMatches(f, base)) return l;
        }
    }
    const ext = extensionOf(base) orelse return null;
    for (std.enums.values(Lang)) |l| {
        const claim = l.spec().claims orelse continue;
        if (std.ascii.eqlIgnoreCase(claim.ext, ext) and headHasMarker(head, claim.markers)) return l;
    }
    for (std.enums.values(Lang)) |l| {
        if (hasExt(l.spec(), ext)) return l;
    }
    return null;
}

/// Language for a path (or bare filename) with no content to consult.
pub fn detectFromPath(path: []const u8) ?Lang {
    return detectFromPathHead(path, "");
}

/// Whether shebang interpreter `interp` names `want`, allowing a
/// version suffix of digits and dots (`python3.12`).
fn interpreterMatches(want: []const u8, interp: []const u8) bool {
    if (!std.mem.startsWith(u8, interp, want)) return false;
    for (interp[want.len..]) |ch| {
        if (!std.ascii.isDigit(ch) and ch != '.') return false;
    }
    return true;
}

/// Interpreter named by a `#!` line: the last path component of the
/// first word, or of the first non-option word after `env`.
fn shebangInterpreter(first_line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, first_line, "#!")) return null;
    const line = std.mem.trim(u8, first_line[2..], " \t\r\n");
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |word| {
        const b = basenameOf(word);
        if (std.mem.eql(u8, b, "env")) continue;
        if (b.len > 0 and b[0] == '-') continue;
        if (b.len == 0) return null;
        return b;
    }
    return null;
}

pub fn detectFromShebang(first_line: []const u8) ?Lang {
    const interp = shebangInterpreter(first_line) orelse return null;
    for (std.enums.values(Lang)) |l| {
        for (l.spec().interpreters) |want| {
            if (interpreterMatches(want, interp)) return l;
        }
    }
    return null;
}

fn detectFromMagic(first_line: []const u8) ?Lang {
    const line = std.mem.trimStart(u8, first_line, " \t\xEF\xBB\xBF");
    for (std.enums.values(Lang)) |l| {
        for (l.spec().magic) |m| {
            if (std.mem.startsWith(u8, line, m)) return l;
        }
    }
    return null;
}

/// Language for a document: name, then extension (with `head` settling
/// ambiguous ones), then a shebang, then a first-line signature. `head`
/// is any prefix of the document; `HEAD_PROBE` bytes is plenty.
pub fn detect(path: ?[]const u8, head: []const u8) ?Lang {
    if (path) |p| {
        if (detectFromPathHead(p, head)) |l| return l;
    }
    const nl = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
    const first = head[0..nl];
    if (detectFromShebang(first)) |l| return l;
    return detectFromMagic(first);
}

/// How much of a document's head `detect` wants to see.
pub const HEAD_PROBE: usize = 4096;

/// LSP `languageId` for a path by name and extension; empty = none.
pub fn languageIdOfPath(path: []const u8) []const u8 {
    const l = detectFromPath(path) orelse return "";
    return l.lspId();
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "languages: every row is complete and every token is usable" {
    for (std.enums.values(Lang)) |l| {
        const s = l.spec();
        try testing.expect(s.name.len > 0);
        // A language nobody can detect is dead weight.
        try testing.expect(s.extensions.len + s.filenames.len + s.interpreters.len + s.magic.len > 0);
        for (s.comments.line) |t| try testing.expect(t.len > 0);
        if (s.comments.block) |b| {
            try testing.expect(b.open.len > 0 and b.close.len > 0);
        }
        for (s.strings) |r| {
            try testing.expect(r.open.len > 0 and r.close.len > 0);
            // The lexer's lookahead window.
            try testing.expect(r.open.len <= 8 and r.close.len <= 8);
        }
        for (s.filenames) |f| {
            try testing.expect(std.mem.count(u8, f, "*") <= 1);
        }
        for (s.extensions) |e| try testing.expect(e.len > 0 and e[0] != '.');
    }
}

test "languages: no extension or exact filename is claimed twice" {
    const all = std.enums.values(Lang);
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| {
            for (a.spec().extensions) |ea| {
                for (b.spec().extensions) |eb| {
                    if (std.ascii.eqlIgnoreCase(ea, eb)) {
                        std.debug.print("extension .{s} claimed by {s} and {s}\n", .{ ea, @tagName(a), @tagName(b) });
                        return error.DuplicateExtension;
                    }
                }
            }
            for (a.spec().filenames) |fa| {
                for (b.spec().filenames) |fb| {
                    if (std.ascii.eqlIgnoreCase(fa, fb)) {
                        std.debug.print("filename {s} claimed by {s} and {s}\n", .{ fa, @tagName(a), @tagName(b) });
                        return error.DuplicateFilename;
                    }
                }
            }
        }
    }
}

test "languages: detection by extension, name, pattern and shebang" {
    try testing.expectEqual(Lang.zig, detectFromPath("/home/x/src/main.zig").?);
    try testing.expectEqual(Lang.zig, detectFromPath("build.zig.zon").?);
    try testing.expectEqual(Lang.c, detectFromPath("box:/tmp/a.c").?);
    try testing.expectEqual(Lang.c, detectFromPath("stdio.H").?);
    try testing.expectEqual(Lang.cpp, detectFromPath("a/b/widget.hpp").?);
    try testing.expectEqual(Lang.python, detectFromPath("tool.py").?);
    try testing.expectEqual(Lang.rust, detectFromPath("lib.rs").?);
    try testing.expectEqual(Lang.typescript, detectFromPath("x.ts").?);
    try testing.expectEqual(Lang.typescriptreact, detectFromPath("x.tsx").?);
    try testing.expectEqual(Lang.json, detectFromPath("a/b/config.json").?);
    try testing.expectEqual(Lang.jsonc, detectFromPath("/p/tsconfig.json").?);
    try testing.expectEqual(Lang.jsonc, detectFromPath("/p/tsconfig.build.json").?);
    try testing.expectEqual(Lang.markdown, detectFromPath("README.md").?);
    try testing.expectEqual(Lang.markdown, detectFromPath("README").?);
    try testing.expectEqual(Lang.make, detectFromPath("Makefile").?);
    try testing.expectEqual(Lang.make, detectFromPath("/src/Makefile.am").?);
    try testing.expectEqual(Lang.dockerfile, detectFromPath("Dockerfile.dev").?);
    try testing.expectEqual(Lang.shell, detectFromPath("/home/u/.bashrc").?);
    try testing.expectEqual(Lang.shell, detectFromPath("PKGBUILD").?);
    try testing.expectEqual(Lang.cmake, detectFromPath("CMakeLists.txt").?);
    try testing.expectEqual(Lang.git_commit, detectFromPath("/r/.git/COMMIT_EDITMSG").?);
    try testing.expectEqual(Lang.gitignore, detectFromPath(".gitignore").?);
    try testing.expect(detectFromPath("noext") == null);
    try testing.expect(detectFromPath("notes.txt") == null);
    try testing.expect(detectFromPath("") == null);
    // A leading dot is a name, not an extension.
    try testing.expect(detectFromPath(".zig") == null);

    try testing.expectEqual(Lang.zig, detectFromShebang("#!/usr/bin/env zig run").?);
    try testing.expectEqual(Lang.python, detectFromShebang("#!/usr/bin/python3.12 -u").?);
    try testing.expectEqual(Lang.python, detectFromShebang("#!/usr/bin/env -S python3 -u").?);
    try testing.expectEqual(Lang.shell, detectFromShebang("#!/bin/sh").?);
    try testing.expectEqual(Lang.javascript, detectFromShebang("#!/usr/bin/env node").?);
    try testing.expect(detectFromShebang("#!/usr/bin/env pythonic") == null);
    try testing.expect(detectFromShebang("not a shebang") == null);

    // Extension wins over shebang; shebang is the fallback; magic last.
    try testing.expectEqual(Lang.c, detect("x.c", "#!/usr/bin/env zig").?);
    try testing.expectEqual(Lang.zig, detect("script", "#!/usr/bin/env zig\nrest").?);
    try testing.expectEqual(Lang.xml, detect("data", "<?xml version=\"1.0\"?>\n<a/>").?);
    try testing.expectEqual(Lang.diff, detect(null, "diff --git a/x b/x\n").?);
    try testing.expect(detect(null, "plain text") == null);
}

test "languages: .h is C unless the head reads as C++" {
    try testing.expectEqual(Lang.c, detectFromPathHead("x.h", "#ifdef __cplusplus\nextern \"C\" {\n#endif\nint f(void);\n").?);
    try testing.expectEqual(Lang.cpp, detectFromPathHead("x.h", "#pragma once\nnamespace sk {\nclass Widget {\n").?);
    try testing.expectEqual(Lang.cpp, detect("inc/v.h", "template <typename T> struct V;").?);
    try testing.expectEqual(Lang.c, detectFromPath("x.h").?);
}

test "languages: comment tokens and LSP ids come from the rows" {
    try testing.expectEqualStrings("#", Lang.python.lineComment().?);
    try testing.expectEqualStrings("//", Lang.rust.lineComment().?);
    try testing.expectEqualStrings("#", Lang.shell.lineComment().?);
    try testing.expectEqualStrings("//", Lang.cpp.lineComment().?);
    try testing.expectEqualStrings("//", Lang.javascript.lineComment().?);
    try testing.expectEqualStrings("--", Lang.lua.lineComment().?);
    try testing.expect(Lang.json.lineComment() == null);
    try testing.expect(Lang.css.lineComment() == null);
    try testing.expectEqualStrings("/*", Lang.css.blockComment().?.open);
    try testing.expectEqualStrings("<!--", Lang.html.blockComment().?.open);

    try testing.expectEqualStrings("cpp", languageIdOfPath("box:/home/x/a.CPP"));
    try testing.expectEqualStrings("shellscript", languageIdOfPath("run.sh"));
    try testing.expectEqualStrings("typescriptreact", languageIdOfPath("a.tsx"));
    try testing.expectEqualStrings("", languageIdOfPath("/etc/passwd"));
}

test "languages: grammar layers name real grammars and markdown has two" {
    try testing.expectEqual(@as(usize, 2), Lang.markdown.grammars().len);
    try testing.expect(Lang.python.hasGrammar());
    try testing.expect(!Lang.ruby.hasGrammar());
    try testing.expectEqual(Grammar.cpp, Lang.cpp.grammars()[0]);
    // Every grammar is reachable from at least one language.
    for (std.enums.values(Grammar)) |g| {
        var used = false;
        for (std.enums.values(Lang)) |l| {
            for (l.grammars()) |lg| {
                if (lg == g) used = true;
            }
        }
        if (!used) {
            std.debug.print("grammar {s} is pinned but no language uses it\n", .{@tagName(g)});
            return error.UnusedGrammar;
        }
    }
}
