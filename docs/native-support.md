# Native backend support policy

Schemurai supports CRuby 4.x only. The currently supported set is the single
minor line 4.0, encoded in `schemurai.gemspec` as `>= 4.0`, `< 4.1`.

The upper bound may advance to the next 4.x minor only in a change that adds
that minor to all of these gates:

- deterministic generation from the pinned Prism version;
- compilation of the committed generated source;
- intrinsic and full backend differential tests;
- source-gem build, installation, and package smoke tests.

The generated tree remains canonical across supported minors: each minor must
reproduce it byte-for-byte rather than committing a version-specific variant.
Prism is a generator-only dependency. It is not needed when installing the
source gem because generated C is committed and packaged.
