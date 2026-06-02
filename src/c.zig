// Aggregated C bindings for sketerm.
//
// Imported as:
//   const c = @import("c.zig").c;
//
// Then used as `c.gtk_application_new(...)`, `c.openpty(...)`, etc.
//
// Zig 0.16 note: we used to call `@cImport` directly here, but Aro
// SEGVs on this header set when run in-process under `zig build-exe`
// (despite succeeding through standalone `zig translate-c`). The build
// runs translate-c as a separate step on `vendor/cimport_root.h` and
// exposes the result as the `cbindings` module, which we just re-export
// so call sites (`c.gtk_…`, `c.openpty`, …) keep working unchanged.

pub const c = @import("cbindings");
