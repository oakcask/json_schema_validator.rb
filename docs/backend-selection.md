# Backend selection

`Schemurai.backend` reports the selected backend. Validators and schema
registries expose the backend captured when they were created.

The `backend:` keyword and `SCHEMURAI_BACKEND` accept `ruby`, `bytecode`,
`native`, or `default`. The production default is explicitly `ruby`. The
`bytecode` backend compiles schema nodes into immutable Ruby instruction streams
and executes them with a Ruby VM. Selecting `native` is strict: absence or load
failure raises `LoadError` and never falls back to Ruby. The native backend
replaces `Internal::Evaluator` with a handwritten C evaluator. All backends
retain the same compiled Ruby schema graph and public result objects.

Set `SCHEMURAI_NATIVE_LOADING=prohibited` for Ruby-oracle runs. In that mode any
attempt to select or probe the native backend is rejected. CI uses this mode to
prove that the Ruby suite does not load native code accidentally.
