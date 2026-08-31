# Native Backend Implementation Plan

## Status

Workstreams 1 and 2 are complete. The compatibility contract is frozen, and
the deterministic generator, typed IR and intrinsic manifests, extension
bootstrap, strict loader, and Ruby/C intrinsic contract harness are in place.
Workstream 3, the lifecycle-complete `type` vertical slice, is complete. The
named Ruby translation root now generates a guarded-specialization native
validator over an immutable, compactable, shareable typed-data graph. Forced
native differential, exception, interruption, GC, thread, Ractor, package, and
performance checkpoints cover the slice.

This document describes the complete migration from the current Ruby
implementation to a generated CRuby native extension. The work is not complete
when a subset of keywords runs natively. It is complete only when the native
backend has the same observable behavior as the Ruby backend for the full
supported feature set.

## Goal

Keep the validator implementation readable and testable as Ruby source while
executing it through a CRuby native extension generated with Prism and built
against the Ruby C API.

The Ruby backend remains the executable specification and test oracle. The
native backend must agree with it for schema compilation, validation, detailed
errors, options, reference resolution, registry behavior, and concurrency
behavior. The native extension must be buildable from the packaged source gem
on every supported CRuby version.

The goal includes:

- a Ruby backend that remains independently executable;
- a deterministic Ruby-to-C generation step based on Prism;
- generated native implementations of schema compilation, dialect and format
  behavior, content handling, validation, and public result construction from
  their maintained Ruby sources;
- a native representation of the compiled schema graph and evaluator state;
- complete behavioral equivalence between the Ruby and native backends;
- correct cooperation with CRuby's GVL and Ractor object-sharing rules;
- CI that proves the Ruby implementation, generated source, native build, and
  backend equivalence in that order;
- source-gem packaging and installation of the native extension.

Native support for only a subset of keywords, validation modes, or public APIs
does not satisfy this goal and must not be released as the completed backend.

## Non-goals

- Adding currently unsupported JSON Schema features or formats as part of the
  native migration.
- Expanding conformance beyond the feature set supported by the Ruby backend at
  the time the equivalence contract is frozen.
- Implementing arbitrary Ruby semantics in the generator.
- Replacing Prism or implementing a Ruby parser.
- Guaranteeing that all validation runs without the GVL. Ruby objects cannot be
  accessed through the Ruby C API while the GVL is released.
- Establishing a fixed performance improvement before the native implementation
  can be measured. Correctness and equivalence are release gates; performance
  is measured and reported separately.
- Shipping platform-specific precompiled gems in the initial implementation.
  The source gem must build successfully on supported environments first.

## Spike findings and resulting decisions

An earlier feasibility experiment reportedly translated the existing
`Evaluator#type?`, `#number?`, and `#decimal` methods with Prism and built the
result against the public Ruby C API. Its artifacts and raw results are not in
this repository. They are informational rather than a performance baseline;
each implementation checkpoint compares its native slice directly with the
current Ruby backend. The experiment indicated that restricted source can be
lowered deterministically, Ruby exceptions can cross the extension boundary,
and a stateless extension can run from a Ractor.

That experiment also indicated that generated C is not inherently faster.
Generic `rb_funcallv` lowering was slower than Ruby. Dedicated C API lowering
was faster than interpreted Ruby in the microbenchmark, but slower than Ruby
with YJIT and bypassed singleton overrides of core predicate methods. A stateless
extension also required `rb_ext_ractor_safe(true)` before CRuby allowed calls
from a non-main Ractor. The implementation therefore adopts these decisions:

- the Ruby C API is the semantic and object-lifecycle foundation;
- Prism AST is first lowered to a repository-owned typed lowering IR, then to
  C; it is not emitted directly as untyped C expressions;
- every known operation has an intrinsic specification covering operand and
  result types, Ruby and native implementations, allocation and exception
  behavior, GC requirements, supported CRuby versions, and semantic
  assumptions;
- generated validation hot paths use only statically typed native operations or
  guarded Ruby-class specializations whose semantic assumptions are proven by
  the compatibility contract;
- an operation that cannot be specialized is rejected during lowering instead
  of silently becoming `rb_funcallv`; generic dispatch is limited to an
  explicit allowlist of cold boundary work and contractual out-of-domain
  compatibility paths;
- native schema records are exposed to generated code only through typed
  intrinsics, never by pretending that a C record is a Ruby `SchemaNode`;
- exception cleanup, GC compaction, typed-data shareability, and an end-to-end
  keyword path are vertical-slice requirements, not late hardening tasks;
- performance is checked at explicit implementation checkpoints with and
  without YJIT, while final production-default selection remains a release
  decision.
- the bootstrap generator, extension build, and native intrinsic harness are
  established together before the lifecycle-complete vertical slice;
- long-running native loops include explicit interrupt checkpoints, because
  `rb_ensure` provides cleanup but does not make a pure C loop interruptible;
- supported CRuby minors are an explicit finite policy reflected by both the
  gemspec and CI matrix, rather than an open-ended consequence of a lower
  version bound.
- the gem as a whole targets CRuby 4.x only; the initial supported minor is
  CRuby 4.0, and a later 4.x minor is claimed only after generation, native
  build, differential, and package CI cover it;
- one repository-owned generator and pinned Prism version define the canonical
  generated output; generation on every supported CRuby minor must reproduce
  that same output byte-for-byte;
- translation roots, typed entry signatures, and the boundary between generated
  and handwritten native code are explicit inputs to the IR and manifest;
- schema inputs are recursively checked as JSON-shaped values at the public or
  internal compilation boundary before they are retained by a graph; rejected
  Ruby-only objects never reach the shareability transition;
- differential cases come from a machine-readable case catalog with observable
  selected, skipped, and pending counts, rather than an implicit collection of
  RSpec examples;
- every performance checkpoint retains its runnable harness, environment, and
  raw measurements.

## Required invariants

The implementation and CI must continuously enforce these invariants:

1. The Ruby source passes its tests without loading or calling the native
   backend.
2. The committed generated C source is exactly reproducible from the committed
   Ruby source and pinned generator toolchain.
3. The native extension tested by CI is built from that generated source.
4. The native backend produces the same observable result as the Ruby backend.
5. A test that explicitly selects the native backend fails if native loading or
   dispatch fails; it must never silently exercise the Ruby backend.
6. The packaged gem contains everything needed to build the extension without
   running the generator or installing Prism as a build-time dependency.
7. Native global state is immutable or synchronization-safe, and validation
   state is never shared accidentally across threads or Ractors.
8. Every optimized intrinsic is linked to its semantic contract and
   differential fixtures; using a dedicated C API is not assumed equivalent to
   Ruby method dispatch without evidence.
9. Every generated function that owns resources or mutates per-call state has
   an idempotent cleanup path exercised by forced exceptions and interruption.
10. Generated validation hot paths contain no generic Ruby method dispatch.
    Every remaining generic invocation site, including callback-based and
    non-`rb_funcallv` APIs, is classified, allowlisted, and tested as cold
    boundary or explicit out-of-domain compatibility behavior.
11. Schema-domain validation happens before graph mutation or retention, and a
    failed shareability transition never publishes a shareable state flag for
    an object that is not actually Ractor-shareable.

## Behavioral equivalence contract

The Ruby backend is the oracle for all behavior already covered by the public
API and test suite. Equivalence includes more than the final validity boolean.

### Schema compilation

The backends must agree on:

- the recursively accepted schema input types and the class and message used to
  reject non-JSON-shaped schema values at the compilation boundary;
- dialect selection and custom meta-schema behavior;
- compilation and reuse of a schema object in a registry;
- base URI handling and URI registration;
- local, external, recursive, and dynamic reference resolution;
- anchor and dynamic-anchor behavior;
- unsupported format handling;
- the class and message of compilation and resolution errors;
- behavior before and after a registry becomes shareable;
- defensive behavior if making an otherwise accepted registry shareable fails;
- lookup through `validator_for`.

### Validation

The compatibility domain must be frozen before optimized intrinsics are
enabled. It has two explicit tiers:

- The supported JSON-shaped domain contains recursively nested `Hash` and
  `Array` values and the scalar values accepted by the Ruby backend, using the
  built-in behavior of those classes. Core-class monkey patches, refinements,
  and singleton overrides are not part of this domain.
- Behavior outside that domain is contractual only where a repository test
  explicitly records a return value or exception. Such fixtures remain part of
  differential verification. A dedicated compatibility branch may use generic
  dispatch when a specialized API would change the recorded behavior, but that
  branch is excluded from the supported-domain hot path and must be explicitly
  identified in generated call-site metadata.

The oracle-freezing change must enumerate the accepted numeric classes and the
handling of subclasses before native evaluation begins. This is a public
compatibility statement and must be documented; the generator must not infer
the boundary from whichever C API is convenient.

For both `valid?` and `validate`, the backends must agree on:

- the validity result;
- all supported keywords and their dialect-specific semantics;
- JSON equality, number handling, and arbitrary-precision behavior;
- annotation propagation required by `unevaluatedItems` and
  `unevaluatedProperties`;
- recursive-reference and dynamic-scope cycle handling;
- format and content options;
- malformed regular expression, address, encoding, and JSON behavior;
- every emitted error's keyword, instance path, schema path, and message;
- error ordering, unless the public contract is deliberately changed before
  equivalence is frozen;
- exceptions raised by explicitly contractual fixtures outside the supported
  JSON-shaped domain.

The comparison harness must serialize results into a canonical representation.
Canonicalization may normalize representation details, but it must not hide an
observable difference. In particular, error ordering must not be sorted away
unless it has first been declared outside the compatibility contract.

### Object lifecycle and concurrency

The backends must agree on:

- whether registries and validators can be shared;
- mutation rejection after `make_shareable`;
- independent validators created from one shareable registry;
- behavior under multiple Ruby threads;
- behavior when independent validators execute in multiple Ractors;
- repeated use after validation errors and raised exceptions.

## Architecture

### Backend boundary

The public API remains backend-neutral. Internally, Ruby and native backends
must be independently selectable so that either can be tested in isolation.
Backend identity must be observable for diagnostics and tests.

The exact selection API may remain internal until release, but it must support
these cases:

- force the Ruby backend;
- force the native backend and fail if it is unavailable;
- select the production default explicitly;
- report the backend actually in use.

The Ruby and native implementations must not share evaluator execution code
during differential tests. Shared immutable fixtures and public value objects
are acceptable; calling back into the Ruby evaluator from the native backend is
not.

### Typed lowering IR, class specialization, and intrinsic boundary

Prism nodes are converted into a small typed lowering IR before C emission. At
minimum the IR distinguishes unknown Ruby `VALUE`, class-refined Ruby `VALUE`,
native graph pointer, native node index, native evaluation-context pointer, C
boolean, integer/size, control-flow region, and owned native allocation. A
class-refined value records whether its proof is an exact built-in class, an
accepted subclass using built-in behavior, or a union of accepted JSON kinds.
A lowering is rejected when operand representation or the class assumptions
required by an operation cannot be established.

Control-flow guards refine Ruby values. For example, a successful built-in
`Hash` guard permits hash intrinsics only within the dominated region. The
guard kind, subclass policy, and behavior excluded by the compatibility domain
are part of the IR and manifest rather than inferred from a convenient C macro.
Refinements are invalidated when a Ruby call, callback, or mutation can make the
assumption stale.

The intrinsic manifest is a versioned repository file and is used by the
generator and its tests. Each intrinsic records:

- accepted Ruby call or syntax forms;
- operand and result IR types;
- Ruby-oracle behavior and native C implementation;
- whether it may allocate, invoke Ruby, raise, or trigger GC;
- whether it is valid while the GVL is held or released;
- cleanup and rooting requirements;
- semantic restrictions such as requiring built-in class behavior;
- the required class refinement and the guard that establishes it;
- dispatch classification: native, guarded specialization, or allowlisted cold
  generic dispatch;
- availability on each explicitly supported CRuby minor.

Operations such as `node.schema`, `node.child`, and `@graph.resolve` lower to
typed graph intrinsics when their receivers are native node or graph values.
The equivalent Ruby source continues to call ordinary Ruby methods. Operations
on instances and retained schema values lower to dedicated Ruby C APIs only
after a dominating class guard or another manifest-declared proof. Unknown
receiver classes are a generation error on validation hot paths. Explicit
generic calls are permitted only in cold boundary code or an out-of-domain
compatibility branch named in the manifest. This boundary lets one maintained
Ruby algorithm execute over different representations without conflating Ruby
objects and C records.

### Ruby source and Prism generator

The maintained implementation is written in a deliberately restricted Ruby
subset. Prism parses that source and a repository-owned generator translates
the accepted AST into C that uses the public Ruby C API.

Before lowering begins, a versioned translation-unit manifest identifies every
maintained Ruby file and method that contributes to the native backend. It
declares named translation roots and their typed entry signatures. Schema
compilation, dialect and format algorithms, content handling, validation, and
public result construction are all generated from maintained Ruby source.
Handwritten C is limited to non-behavioral runtime and representation
intrinsics, such as typed-data access, allocation, GC integration, and public
Ruby C API operations. It may not contain an alternative implementation of
schema or validation semantics. A production behavior may not fall into an
unowned gap between the translation-unit manifest and the intrinsic manifest.

The first keyword slice requires a Ruby-executable dispatch seam. The seam must
allow the `type` path to be selected and tested without translating or stubbing
unrelated branches of the monolithic `evaluate_valid` method. It is maintained
as part of the Ruby oracle and is not native-only control flow.

The generator must:

- accept only explicitly supported node types and call forms;
- reject unsupported syntax with a source location and actionable error;
- give known operations explicit lowering rules rather than relying on generic
  Ruby method dispatch;
- type-check the lowering IR and reject ambiguous receiver representations;
- emit and verify class guards before every guarded specialization;
- reject implicit generic dispatch and emit a machine-readable inventory of
  the explicitly allowlisted generic call sites;
- obtain call lowering, exception, and lifetime rules from the intrinsic
  manifest;
- preserve Ruby truthiness, control flow, exception cleanup, and integer/value
  lifetime semantics where they are part of the implementation;
- produce deterministic output independent of timestamps and checkout paths;
- include generator, source, intrinsic-manifest, Prism, and lowering-IR version
  fingerprints for diagnostics without introducing nondeterminism;
- have unit tests for every supported AST lowering;
- have rejection tests for unsupported or ambiguous Ruby constructs, missing
  class proofs, and non-allowlisted generic calls.

The generator is not a general Ruby compiler. The accepted subset evolves only
when a required implementation construct cannot be expressed clearly with the
existing lowering rules.

Prism is declared directly in a generator-only dependency group and pinned by
the repository lockfile. Generator CI installs that group. Prism and the
generator are neither runtime dependencies nor source-gem build dependencies;
installation compiles only committed generated C.

One repository-owned generator and pinned Prism version define canonical
committed output. The generator runs on every supported CRuby minor and must
produce that same output byte-for-byte. Each minor also compiles and runs the
committed artifact; no matrix entry creates a separate canonical tree.

Generated C is committed and included in the source gem. Normal development
regenerates it deliberately. CI regeneration writes to a temporary location
and compares it byte-for-byte with the committed source rather than modifying
the checkout.

### Native schema representation

The schema-compilation algorithm is generated from its maintained Ruby source
and produces an immutable native intermediate representation through typed
graph-construction intrinsics. The representation should use indexes and
compact native records for nodes, children, references, keyword metadata, and
precomputed validation data instead of repeatedly dispatching through Ruby
`SchemaNode` objects on the validation hot path.

Construction happens while the GVL is held because it reads Ruby schemas and
may allocate Ruby exceptions and public objects. The native representation must
have explicit ownership, mark, compact, free, and size functions suitable for
CRuby typed data.

Retained movable `VALUE`s are marked with `rb_gc_mark_movable` and rewritten in
the compact callback with `rb_gc_location`. Non-retained generated temporaries
remain visible to GC for their complete live range and use `RB_GC_GUARD` where
compiler optimization could otherwise end that range. Generated constants are
immutable registered roots or fields of marked typed data; the generator may
not create an untracked static `VALUE`.

Once a registry becomes shareable:

- all references are resolved;
- the native graph is immutable;
- retained Ruby objects are themselves shareable;
- the typed-data type declares `RUBY_TYPED_FROZEN_SHAREABLE`, the wrapper is
  frozen, and `rb_ractor_make_shareable` verifies the complete retained graph;
- no lazy cache mutation remains;
- mutable evaluation state is allocated per validator or per call.

Schema-domain validation rejects unshareable Ruby-only schema values before
they are retained. The shareable state is published only after the wrapper and
all retained values are actually shareable. The oracle contract decides whether
accepted caller-owned schema values are frozen in place or copied. A defensive
failure path may not leave a true shareable-state flag on a non-shareable graph.

### Native evaluation

The native evaluator implements both fast boolean validation and detailed
validation. It must preserve the Ruby evaluator's distinction between these
paths, including the cases where annotation collection requires the detailed
path.

Ruby `Hash`, `Array`, `String`, `Numeric`, and other `VALUE` objects are accessed
only while the GVL is held and through intrinsics authorized for the current
class refinement. The evaluator branches on JSON kind once, refines the value
for the dominated region, and then uses class-specific operations instead of
repeating Ruby method dispatch for each keyword. The initial backend may
therefore retain the GVL through validation. This is compatible with native
execution and Ractor-safe parallelism when the extension and shared objects
obey Ractor rules, but it is not equivalent to a generally GVL-free validator.

GVL-free execution may be added where the complete working set has first been
converted into C-owned memory and the no-GVL section calls no Ruby C API. Any
such path must be selected by measurement because snapshot conversion and GVL
transitions have a cost. It must use the same differential test suite as the
normal native path.

### Error construction and cleanup

Detailed validation should collect native error records during traversal and
materialize public Ruby error objects at the boundary. All paths that can raise
must preserve ownership and restore per-call evaluator state. Native resources
must be released correctly after:

- successful validation;
- ordinary validation failure;
- schema compilation errors;
- Ruby exceptions raised by C API calls;
- thread interruption;
- repeated validation on the same validator.

Each public native entry point allocates a per-call context and executes its
body through `rb_ensure`; the ensure callback restores evaluator state and
releases owned native allocations idempotently. Source `ensure` regions lower
to nested `rb_ensure` regions. Source `rescue` and any operation that must
inspect an exception lower through `rb_protect`, preserving the original
exception when it is not handled. No long-lived validator object stores mutable
instance paths, recursion guards, callbacks, or error buffers.

The generator test suite must force an exception at every allocating or
Ruby-calling intrinsic used inside an owned-resource region. Native tests also
cover asynchronous interruption, a second call after an exception, GC stress,
and GC compaction during callbacks.

## CI pipeline

The required pipeline has four ordered gates. Later jobs consume artifacts from
earlier jobs so the tested native library is traceable to the tested Ruby source
and generated C.

### Gate 1: Ruby oracle

Run lint and the complete Ruby-backend test suite with native loading disabled.
This includes the repository specs, all applicable JSON Schema Test Suite cases,
format/content cases, registry tests, and Ractor tests.

“Applicable” is defined by a committed case catalog. CI reports the number of
selected, skipped, and pending cases by dialect and feature, and fails if a case
loses its classification. RSpec and the serialized oracle runner consume the
same catalog where their case shapes overlap.

The gate must assert that the active backend is Ruby. Passing because a locally
built extension was auto-loaded is a CI failure.

### Gate 2: deterministic generation

Using each supported Ruby with the pinned Prism version:

1. install the explicit generator-only dependency group;
2. validate the intrinsic manifest and its CRuby-version availability;
3. parse the maintained Ruby implementation;
4. type-check the lowering IR and validate the supported subset;
5. generate C, a cleanup/lifetime map, and a classified Ruby-call-site
   inventory into an isolated temporary directory;
6. compare every generated file with its committed counterpart;
7. upload the verified generated tree as an artifact.

Generator, manifest-schema, Ruby-side intrinsic expectation, and rejection
tests run in this gate. It also generates the native intrinsic contract and
forced-exception fixtures consumed by Gate 3. A source edit without regenerated
C, a manifest edit without updated contract fixtures, a generator edit that
changes output, or nondeterministic output fails here.

The call-site inventory gate fails if a validation hot-path call is classified
as generic or if generated C contains an unreported Ruby dispatch site. Cold
generic calls require a manifest entry explaining why specialization is not
applicable and a fixture that exercises the call.

The audit recognizes every Ruby invocation mechanism used by the emitter,
including `rb_funcall*`, block and iterator callbacks, and intrinsic callbacks;
it does not equate the absence of `rb_funcallv` with the absence of dispatch.

### Gate 3: native build

Build the extension from the verified generation artifact for every supported
CRuby version. Before the intrinsic manifest is created, the gemspec is changed
from open-ended `>= 3.4` to the initial CRuby 4.0-only range (`>= 4.0`, `< 4.1`).
The upper bound is advanced one 4.x minor at a time only when that minor is
included here. macOS and Windows are added before claiming support for those
native build environments.

This gate must:

- compile only from files intended to ship in the source gem;
- apply strict warnings to project-owned C without turning Ruby-header warnings
  into false failures;
- load the resulting extension and assert its backend identity;
- expose and verify source, generator, manifest, Prism, and lowering-IR
  fingerprints in its build metadata;
- execute the generated native side of every intrinsic contract and
  forced-exception fixture, comparing it with Gate 2's Ruby-side expectations;
- verify at runtime that guarded specializations are reached for the supported
  JSON-shaped corpus and that cold generic branches are not reached;
- compile and run on every CRuby minor claimed by the finite gemspec policy;
  newly released minors are added to that policy only with matching CI;
- run typed-data mark/compact/free/size, `GC.compact`, exception cleanup, and
  Ractor-shareability tests before uploading it;
- upload the built extension and build metadata for differential testing.

A separate Linux job should build and run with AddressSanitizer and
UndefinedBehaviorSanitizer. Sanitizer findings are correctness failures, not
performance findings.

### Gate 4: differential verification

Run Ruby and native backends in separate processes over identical, serialized
inputs. Each process emits canonical result records. A comparator requires
exact agreement under the behavioral equivalence contract.

Separate processes prevent constant tables, caches, monkey patches, or backend
selection state from contaminating the comparison. They also make native
crashes and accidental Ruby fallback unambiguous.

The differential corpus includes:

- every repository spec that describes backend behavior;
- all currently supported official suite cases for Draft 7, Draft 2019-09, and
  Draft 2020-12;
- supported optional format and content cases;
- targeted fixtures for reference cycles, dynamic scope, annotations, numeric
  precision, error ordering, and repeated validation;
- compatibility-domain fixtures for core subclasses, singleton overrides,
  coercion, mutation during iteration, and exceptional numeric methods;
- registry construction and shareability scenarios;
- thread and multi-Ractor scenarios;
- deterministically seeded generated schemas and instances.

Random differential testing must print and retain its seed and minimal failing
input. It supplements the fixed corpus and is not allowed to make CI flaky.

### Package verification

After the four gates pass, build the source gem from the same committed files.
For every supported CRuby version, install it in a clean environment so the
native extension is compiled from the gem contents, then run smoke and
differential tests against the installed package.

Package verification must detect:

- missing extension sources or headers;
- an incorrect gem extension declaration;
- dependencies on repository-only files;
- an accidental generator or Prism requirement at install time;
- failure to load the installed native library;
- production backend selection that differs from the tested selection.

## Test organization

Backend-independent behavior should be expressed once and executed against both
implementations. Backend-specific tests are limited to loading, identity,
native memory ownership, generator behavior, and concurrency mechanisms that do
not exist in Ruby.

The standalone differential runner accepts serialized test cases and emits one
record per operation. A record includes enough context to reproduce a mismatch:

- case identifier and deterministic seed where applicable;
- backend identity and Ruby version;
- operation and options;
- success value or normalized exception;
- normalized detailed errors;
- schema and instance fingerprints.

The runner's inputs are produced from the committed case catalog. Cases that
cannot be represented as a schema/instance pair, such as registry lifecycle and
concurrency scenarios, use named operation records with explicit setup and
expected state transitions. “Every repository spec” is not treated as an
executable serialization format.

Large schemas and instances should be stored once as fixtures or regenerated
from a recorded seed, rather than duplicated in backend-specific tests.

## Implementation workstreams

The workstreams below establish dependency order, but they do not narrow the
project goal. Intermediate branches may contain an incomplete backend; no
intermediate subset counts as delivery of this plan.

### 1. Freeze and encode the oracle contract

- Make backend selection and identity explicit.
- Ensure the existing suite can run with native loading prohibited.
- Define and enforce the recursive JSON-shaped schema input domain at the
  public or internal compilation boundary, before graph mutation or retention.
- Create a machine-readable case catalog shared by the oracle runner and
  applicable RSpec examples; record selected, skipped, and pending counts.
- Enumerate the supported JSON-shaped classes, numeric classes, subclass
  behavior, and explicitly contractual non-JSON inputs.
- Add fixtures for singleton overrides, core subclasses, coercion, mutation
  during iteration, and exceptional numeric methods; classify each fixture as
  supported-domain or explicit out-of-domain behavior.
- Add coverage for observable behavior not currently asserted, especially
  detailed errors, ordering, exceptions, registry lifecycle, and Ractor use.
- Test rejection of Ruby-only schema values before sharing and retain a
  defensive test that the public state flag agrees with `Ractor.shareable?` if
  an unexpected shareability failure occurs.
- Implement the serialized oracle runner and result comparator.
- Record interpreter and YJIT correctness, throughput, and allocation baselines
  for the Ruby backend.

Exit criteria: the schema and instance compatibility-domain document, case
catalog, case-selection counts, and canonical oracle records are reviewed;
out-of-domain schemas are rejected before retention; and Ruby-only CI proves
that native code cannot load.

### 2. Bootstrap generation and define the typed IR and intrinsic manifest

Status: complete. The CRuby 4.0 bootstrap CI compiles committed generated C,
checks byte-for-byte regeneration with pinned Prism, runs rejection tests, and
compares the Ruby and C intrinsic implementations, including exceptional and
non-main-Ractor execution. The source-gem smoke test builds and loads the
extension without the generator dependency.

- Make the whole gem CRuby 4.x-only, encode the initial `>= 4.0`, `< 4.1` range
  in the gemspec, and compile the lifecycle/API spike on every selected minor.
- Document how the gemspec upper bound advances when a later 4.x minor gains
  complete generation, native build, differential, and package coverage.
- Add the translation-unit manifest covering the generated compilation,
  evaluation, dialect, format, content, and result-construction source files,
  with named roots and typed entry signatures.
- Define and enforce the handwritten-C boundary: representation, ownership, GC,
  loader, and Ruby C API intrinsics only, with no schema or validation
  semantics.
- Add the extension build, strict native loader, and backend identity needed to
  execute intrinsic contracts.
- Add a minimal deterministic Prism generator for the first vertical slice;
  keep unsupported syntax rejection explicit rather than anticipating the full
  evaluator grammar.
- Define the lowering IR types, control-flow regions, ownership states, and
  rules for values live across Ruby C API calls.
- Define class-refinement types, dominating guard rules, invalidation rules,
  and the exact-class versus accepted-subclass distinction.
- Create the versioned intrinsic manifest with Ruby semantics, C lowering,
  allocation, exception, GVL, cleanup, rooting, and version metadata.
- Specify typed graph intrinsics for schema access, child lookup, and reference
  resolution before implementing either the complete generator or graph.
- Declare Prism directly in a pinned generator-only dependency group.
- Add contract tests that run each intrinsic's Ruby and C implementation over
  its supported and exceptional fixtures.
- Add rejection tests proving that unknown receivers and missing class guards
  cannot lower to implicit `rb_funcallv` calls.

Exit criteria: the complete production source boundary has an owner, ambiguous
receiver or ownership types are rejected, and every intrinsic needed by the
first vertical slice has executable contract tests on every supported CRuby
minor.

### 3. Build a lifecycle-complete vertical slice

Status: complete. The generated `type` slice is strict: known unsupported
validation keywords raise instead of falling back to the Ruby evaluator. Raw
interpreter and YJIT samples show that the representation removes enough Ruby
dispatch to continue expanding the generator.

- Refactor and test a Ruby-executable dispatch seam that exposes the `type`
  slice as a named translation root without native-only stubs for the rest of
  `evaluate_valid`.
- Implement one typed-data graph containing a retained schema value and one
  immutable native node.
- Implement mark, compact, free, and size callbacks, declare
  `RUBY_TYPED_FROZEN_SHAREABLE`, freeze the completed wrapper, and verify it
  with `rb_ractor_make_shareable`.
- Lower boolean validation for the `type` keyword from the real maintained Ruby
  source through the typed IR and intrinsic manifest.
- Specialize the supported JSON classes behind explicit guards and produce no
  generic Ruby dispatch in the validation loop.
- Audit the slice's globals, call `rb_ext_ractor_safe(true)`, and fail a
  non-main-Ractor smoke test if CRuby rejects the extension.
- Run it through forced-native separate-process differential tests.
- Exercise successful use, forced exceptions, asynchronous interruption,
  repeated use, GC stress, `GC.compact`, threads, and multiple Ractors.
- Exercise the defensive shareability failure path without publishing a false
  shareable state.
- Measure compilation and repeated validation with and without YJIT. Keep the
  spike's generic-dispatch variant only as a diagnostic baseline; the candidate
  slice is the guarded-specialization implementation and must justify
  continuing in both runtime modes.

Exit criteria: the slice is generated from the named Ruby translation root, has
no Ruby evaluator fallback or hot-path generic dispatch, passes lifecycle and
differential tests on every supported CRuby minor, builds from intended package
files, and shows whether the chosen representation removes enough dispatch to
continue. Its benchmark harness, environment, and raw samples are retained. If
it does not remove enough work, revise the representation or stop before
expanding coverage.

### 4. Expand the deterministic generator

Status: complete. Every maintained translation source is parsed into a
deterministic typed syntax IR, and the generated source records both its source
and IR fingerprints. The lowering manifest exhaustively classifies the Prism
forms currently present and rejects an undeclared form with its source location.
Control-region primitives cover protected calls, idempotent ensure cleanup, and
iterator callbacks. Owned regions require forced-exception fixtures for every
allocating or Ruby-calling intrinsic, while graph access and compatibility call
classification remain manifest-only. Generator sources, manifests, and source
provenance are included in the source gem.

- Expand the accepted Ruby AST subset and lowering rules from the bootstrap
  generator.
- Expand Prism diagnostics and deterministic C emission for the complete
  maintained source.
- Implement `rb_ensure`/`rb_protect` lowering, block and iterator lowering, and
  cleanup-region generation before broad keyword translation.
- Generate lifetime guards and typed-data access only from manifest rules.
- Generate class guards, refinement regions, and call-site classifications only
  from manifest rules.
- Add generator unit and rejection tests.
- Add forced-exception tests for every Ruby-calling or allocating intrinsic in
  an owned-resource region.
- Add generated-source drift checking.
- Include generated files and generator provenance in package metadata.

Exit criteria: every AST form used by every translation unit is either supported
with tests or rejected with an actionable source location; the repository-owned
generator and pinned Prism produce the same byte-for-byte output on every
supported CRuby version, and that output compiles on every supported version.

### 5. Implement native ownership and schema compilation

- Expand the proven typed-data structures and lifecycle functions.
- Generate schema compilation, reference resolution, registry behavior, and
  dialect handling from their maintained Ruby translation units.
- Expose graph allocation, indexing, lookup, and ownership to generated code
  only through typed non-semantic intrinsics; do not introduce a handwritten C
  source of schema semantics.
- Compile all schema nodes, dialect metadata, child relationships, formats,
  anchors, and references into the native graph.
- Implement atomic compilation and cleanup on errors.
- Implement immutable/shareable registry transition and lookup.
- Run GC, compaction, exception, and Ractor tests as each retained field type is
  added rather than waiting for graph completion.
- Re-run compilation, memory, and repeated-validation checkpoints after the
  complete graph representation is available.

### 6. Implement the complete native evaluator

- Generate boolean and detailed validation paths from their maintained Ruby
  translation units.
- Cover all supported type, enum, combiner, numeric, string, array, and object
  behavior.
- Cover references, dynamic scope, recursion guards, annotations, unevaluated
  keywords, format assertions, and content assertions.
- Generate format algorithms and content handling from their maintained Ruby
  translation units; calls into standard libraries use manifest-declared
  intrinsics rather than handwritten format or content semantics.
- Generate public result and detailed-error construction from the maintained
  Ruby source, materializing Ruby objects through typed boundary intrinsics.
- Remove every evaluator fallback from the forced-native path.
- Reject each keyword implementation until all supported-domain operations in
  its validation loop have typed or guarded-specialized lowerings.
- Expand differential fixtures and benchmark checkpoints with each keyword
  category; a regression triggers lowering review before the next category.

### 7. Complete concurrency and lifecycle safety

- Re-audit the extension's Ractor-safe declaration after every expansion of
  global and retained state.
- Verify shareable typed data and retained Ruby values.
- Stress independent validators across threads and Ractors.
- Insert and test interrupt checkpoints in long native loops; `rb_ensure`
  remains responsible for cleanup after the interrupt is observed.
- Run sanitizers over compilation, validation, exceptions, and GC compaction.
- Confirm that repeated calls do not retain instance data or stale paths.
- Verify the generated cleanup-region map against every source `ensure` and
  `rescue` location.

### 8. Complete CI and packaging

- Connect the four gates with verified artifacts.
- Add the supported Ruby and operating-system build matrices.
- Build and install the source gem in clean environments.
- Run package smoke and differential tests.
- Document compiler requirements, backend identity, and troubleshooting.

### 9. Measure and select the production default

- Run existing build, suite, repeated-validation, allocation, format, and
  detailed-error benchmarks against both backends.
- Add native memory measurements not visible in Ruby allocation counters.
- Measure thread and Ractor workloads separately from single-thread throughput.
- Investigate GVL-free snapshots only if measurements justify their complexity.
- Select the production default only after all equivalence and package gates
  pass.
- Compare the final results with the vertical-slice checkpoints and document
  whether later complexity changed the original performance decision.
- Commit or retain the runnable harness configuration and raw samples for every
  reported checkpoint, including Ruby version, compiler flags, warmup,
  measurement method, and YJIT state.

## Release policy

The native backend is not considered ready while any supported operation falls
back to the Ruby evaluator. During development it must be opt-in and clearly
identified. A forced-native test configuration treats absence, load failure, or
fallback as an error.

Changing the production default is a separate release decision made only after
this plan's completion criteria pass on the supported matrix. If a runtime
fallback is retained for installation portability, it must be observable and
must not apply when the caller or CI explicitly requires native execution.

The Ruby backend remains packaged as the oracle, portability fallback, and a
diagnostic comparison path unless a later decision explicitly removes it.

## Risks and mitigations

### Generator complexity

Trying to support arbitrary Ruby would recreate a compiler and obscure the
native semantics. The generator therefore rejects everything outside a small,
documented language and grows only through reviewed lowering rules. The typed
IR and intrinsic manifest keep syntax support separate from representation and
C API choices.

### Ruby source and native representation divergence

The readable Ruby evaluator operates on Ruby objects while the native evaluator
uses compact records. Translating calls without receiver types can silently
retain Ruby dispatch or access the wrong representation. Typed graph intrinsics
are defined before graph expansion, and the generator rejects any receiver
whose representation is not statically known.

### Unsound Ruby-class specialization

A C API can bypass a singleton override, subclass method, coercion, or mutation
hook that the Ruby source would invoke. Every specialization therefore requires
a dominating guard and a manifest-declared compatibility-domain assumption.
Differential fixtures cover exact built-in classes, accepted subclasses, and
explicitly contractual out-of-domain values. A missing proof is a generation
error, not a reason to insert generic dispatch into the hot path.

### Semantic drift

Generated C can compile successfully while differing subtly in truthiness,
numeric conversion, exceptions, cleanup, or iteration order. Separate-process
differential testing over fixed and generated corpora is the primary control.
Optimized intrinsics additionally require manifest-declared assumptions and
fixtures covering each class guard and the cold generic-dispatch boundary.

### Non-local exception cleanup

A Ruby exception or thread interruption can bypass ordinary C control flow and
leave native memory or evaluator state live. Public entry points and generated
exception regions use `rb_ensure` with idempotent per-call cleanup, while forced
exception and interruption tests cover each owning region.

### Performance without useful work removal

Moving Ruby dispatch behind `rb_funcallv` adds a C boundary without removing
work and may be slower than Ruby or YJIT. Generic dispatch is therefore not a
production lowering for validation hot paths. The lifecycle-complete vertical
slice and per-category checkpoints verify that guarded specialization removes
enough work before implementation breadth increases. A checkpoint can require
representation redesign even though no fixed release speedup is promised.

### Ruby C API and ABI differences

Code that builds on one CRuby release may fail or behave differently on another.
Only public APIs should be used, and every supported CRuby version must compile
and execute the differential suite independently.

### Memory and GC safety

Native references can be lost to the marker, retained after use, or invalidated
by compaction. Typed-data lifecycle tests, GC compaction tests, sanitizers, and
exception-path tests are required before release.

### Ractor safety

A mutable native cache or unshareable retained `VALUE` can invalidate the
existing registry contract. Shareability is an explicit transition that resolves
all lazy state and freezes the graph before it is exposed to another Ractor.

CRuby's in-place shareability traversal can freeze objects before encountering
an unshareable descendant and raising. Recursive schema-domain validation keeps
Ruby-only values out of the retained graph, and the implementation publishes
shareable state only after the transition succeeds.

### False differential success

Both runners could accidentally use the Ruby backend. Backend identity is
included in every result stream, and forced-native mode fails rather than
falling back.

### Native build portability

The development checkout may hide missing files or undeclared dependencies.
Clean installation of the built source gem is required on every supported
matrix entry.

## Completion criteria

This plan is complete only when all of the following are true:

- The Ruby backend independently passes the complete oracle suite.
- The supported JSON-shaped domain, numeric classes, subclass behavior, and
  explicitly contractual out-of-domain behavior are documented and encoded as
  fixtures.
- Non-JSON-shaped schema values are rejected at the compilation boundary before
  graph mutation or retention.
- The machine-readable case catalog accounts for selected, skipped, and pending
  cases, and Ruby and differential runners agree on case identity.
- The finite CRuby support set, repository-owned generator, and pinned Prism
  version are documented before intrinsic availability is accepted, and every
  supported CRuby reproduces the canonical output.
- The translation-unit manifest assigns every production behavior to generated
  maintained Ruby source and defines each translation root's typed signature;
  handwritten C is limited to tested non-semantic runtime and representation
  intrinsics.
- The typed lowering IR rejects ambiguous representations, and every emitted
  intrinsic has a complete manifest entry and executable contract tests.
- Class-specific intrinsics are dominated by verified guards, and refinement
  invalidation rules are covered by generator tests.
- The generated call-site inventory and C-source audit prove that validation
  hot paths contain no generic Ruby dispatch; every remaining generic call is
  an allowlisted cold or out-of-domain compatibility site.
- Generation from the maintained Ruby source is deterministic and the committed
  C source is current.
- The generated cleanup/lifetime map covers every supported source `ensure`,
  `rescue`, Ruby-calling intrinsic, and owned allocation region.
- The native extension builds from packaged sources on every supported CRuby
  and operating-system combination.
- Forced-native mode contains no Ruby evaluator fallback.
- Ruby and native result streams agree for the complete fixed differential
  corpus.
- Ruby and native result streams agree for the deterministic generated corpus.
- Compilation behavior, validation errors, exception behavior, options,
  registries, references, and annotations are equivalent.
- Thread and Ractor tests pass with independent validators and shareable
  registries.
- Defensive shareability failures never publish a true shareable flag for an
  object that is not Ractor-shareable.
- GC compaction and sanitizer jobs report no native ownership defects.
- Forced exceptions and asynchronous interruptions release per-call resources,
  and the same validator remains reusable afterward.
- The installed source gem loads the native backend and passes its package
  verification suite.
- Prism is a pinned direct generator dependency but is absent from runtime and
  packaged-extension build dependencies.
- Existing benchmarks have been run against both backends and any regression or
  tradeoff is documented for interpreter and YJIT runs, with reproducible
  harness configuration and raw samples retained.
- Backend selection and fallback behavior are documented and observable.

No keyword subset, benchmark improvement, successful compilation, or partial
test-suite pass can substitute for these completion criteria.
