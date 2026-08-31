# Native backend support policy

Schemurai supports CRuby 4.x only. The currently supported set is the single
minor line 4.0, encoded in `schemurai.gemspec` as `>= 4.0`, `< 4.1`.

The native source gem is continuously built and tested on current GitHub-hosted
Ubuntu, macOS, and Windows runners. Installation requires a C99 compiler, Ruby
headers, and `make`: GCC or Clang with the CRuby development package on Linux,
Xcode Command Line Tools on macOS, or the MSYS2/MinGW toolchain supplied by
RubyInstaller on Windows. Platform-specific precompiled gems are not shipped.

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

The source gem also retains the repository-owned generator, translation
sources, typed IR and intrinsic manifests, and generation entry point as build
provenance. Installation still compiles only the committed generated C and does
not execute the generator. Every maintained translation source and its lowered
syntax IR are fingerprinted in that C file, so changing any translation unit
without regeneration fails the byte-for-byte drift check.

## Backend identity and troubleshooting

After installation, `Schemurai.backend` reports the production selection and a
validator's `backend` reports what it actually uses. The production default is
Ruby based on the retained interpreter and YJIT measurements in
`native-performance.md`; request `backend: :native` when confirming the
extension. That selection is strict and raises `LoadError` instead of falling
back.

If native installation fails, first confirm that `ruby --version` reports CRuby
4.0 and that the platform compiler and `make` are available in the same shell.
The extension is compiled by RubyGems from the committed files under `ext/`; it
does not run `script/generate-native` and does not need Prism. Preserve the
`gem install` compiler output when reporting a failure because it identifies the
missing header, toolchain, or unsupported compiler option.

If installation succeeds but loading fails, run this diagnostic from outside a
repository checkout so a locally built extension cannot shadow the installed
gem:

```sh
ruby -rschemurai -e 'p Schemurai.compile({"type" => "integer"}, backend: :native).backend'
```

The expected output is `:native`. `SCHEMURAI_NATIVE_LOADING=prohibited` is a
Ruby-oracle CI guard and intentionally makes native selection fail.
