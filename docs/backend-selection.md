# Backend selection

`Schemurai.backend` reports the selected backend. Validators and schema
registries expose the backend captured when they were created.

The `backend:` keyword and `SCHEMURAI_BACKEND` accept `ruby`, `vm`, or
`default`. The production default is explicitly `ruby`. The `vm` backend
compiles schema nodes into immutable Ruby instruction streams as the schema
graph is built and executes them with the validator VM. Validators from the
same VM registry reuse those streams. Both backends retain the same compiled
Ruby schema graph and public result objects.
