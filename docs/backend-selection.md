# Backend selection

`Schemurai.backend` reports the selected backend. Validators and schema
registries expose the backend captured when they were created.

The `backend:` keyword and `SCHEMURAI_BACKEND` accept `ruby`, `bytecode`, or
`default`. The production default is explicitly `ruby`. The
`bytecode` backend compiles schema nodes into immutable Ruby instruction streams
and executes them with a Ruby VM. Both backends retain the same compiled Ruby
schema graph and public result objects.
