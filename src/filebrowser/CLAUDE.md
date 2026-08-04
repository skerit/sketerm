<!-- Pointer: the file-browser guidance lives with the UI side. -->

# File browser (pure helpers)

This directory holds the allocation-free helpers behind `sketerm files`.
The full contract — daemon-owned file ops, streaming listings, the
`renderList` windowing rule, thumbnail cache formats, and the state files —
is in `src/ui/browser/CLAUDE.md`. Read it before changing anything here that
the UI consumes.
