# Backend selection

`Schemurai.backend` reports the selected backend. Validators and schema
registries expose the backend captured when they were created.

The `backend:` keyword and `SCHEMURAI_BACKEND` accept `ruby`, `native`, or
`default`. The production default is explicitly `ruby`. Workstream 9 retained
Ruby after correctness-gated interpreter and YJIT measurements found material
native regressions across build, validation, allocation, thread, and Ractor
workloads. The evidence and revisit rule are in `native-performance.md`.
Selecting `native` is strict: absence or load failure raises `LoadError` and
never falls back to Ruby.

Set `SCHEMURAI_NATIVE_LOADING=prohibited` for Ruby-oracle runs. In that mode any
attempt to select or probe the native backend is rejected. CI uses this mode to
prove that the Ruby suite does not load native code accidentally.
