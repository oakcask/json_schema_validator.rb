# Native production-default decision

The production default remains the Ruby backend. The native backend is strict
and fully selectable, but its final Workstream 9 measurements materially
regress build, detailed errors, allocations, and concurrency on the measured
CRuby 4.0 Linux environment. Correctness and package gates passed before these
measurements were taken.

## Final measurements

The retained raw samples use CRuby 4.0.6, GCC 13.3, `-O3 -fno-fast-math`, five
samples, and the complete 1,877-case selected Draft 2020-12 corpus. Times below
are medians. A ratio greater than 1 means native took longer.

| Workload | Interpreter native/Ruby | YJIT native/Ruby |
| --- | ---: | ---: |
| Build 439 corpus schemas | 188.30x | 208.57x |
| Build and validate the corpus | 87.56x | 120.26x |
| Repeated boolean validation | 1.57x | 0.91x |
| Format assertion | 1.28x | 1.15x |
| Detailed errors | 1.64x | 1.86x |
| Four-thread validation | 1.55x | 1.64x |
| Four-Ractor validation | 1.86x | 1.95x |

Native repeated validation allocated 3.14 times as many Ruby objects in both
runs. The six-node typed-data graph occupied 568 bytes after compacting node
indexes, masks, and flags; its inferred node record is 80 bytes instead of 104.
These native bytes are not visible to Ruby allocation counters.

YJIT repeated validation is the one timed workload in which native is faster,
by about 9%. That isolated gain does not offset the broader regressions.

## Bottleneck analysis

The build regression is algorithmic rather than a compiler-flag problem. The
extension inherits `-O3 -fno-fast-math`. Within one registry, every native
compile serializes the accumulated graph, imports every retained node into a
new typed-data graph, and rebuilds a Ruby `GraphView` for that validator. A
scaling check with independent one-node schemas grew from 5.72x Ruby time at 10
schemas to 22.45x at 50, 41.66x at 100, 65.92x at 200, and 109.66x at 400. The
repeated whole-graph work is quadratic; fixed ID and node-layout optimizations
cannot remove it.

Validation does not yet run the complete evaluator as a C hot path.
`Schemurai::Native::Execution` is a duplicate of the Ruby
`Internal::Evaluator`, executed over Ruby `Node` and `GraphView` wrappers.
RubyProf attributed the largest self-time share to
`Native::Execution#evaluate_valid` (21.46%); `Native::Node#child` and
`Native::GraphView#child` added 4.55% and 2.57%. Native therefore retains the
Ruby evaluation work and adds wrapper and Ruby/C graph-lookup boundaries.

A new `Execution` is allocated for every native validation so the validator can
remain shareable. Over 100,000 boolean validations, Ruby and a diagnostic reused
native execution each allocated about 350,000 objects, while the public native
path allocated 1,100,015. Reusing an execution reduced native interpreter time
from 0.710 seconds to 0.535 seconds in the same diagnostic, versus 0.473 seconds
for Ruby. This isolates the per-call object as most of the allocation gap and
about one quarter of native single-thread time; GraphView overhead explains the
remaining gap.

The initial thread result also exposed an avoidable checkpoint cost: every
short child/reference loop scheduled the thread at index zero. Deferring the
first checkpoint until iteration 1,024 reduced the interpreter four-thread
ratio from 22.98x to 1.55x while preserving long-loop interruption tests. The
remaining thread and Ractor differences track the single-call wrapper costs.

## Reproduction and revisit rule

Run `benchmark/native_release.rb` with the built extension on the load path,
once with `ruby --disable-yjit` and once with `ruby --yjit`. The harness records
Ruby and compiler identity, compiler flags, warmup, iteration counts, corpus
size, allocation method, native memory method, correctness digest, and every raw
sample. Environment variables documented in `benchmark/README.md` can shorten
diagnostic runs, but default-selection evidence uses the committed defaults.

`benchmark/production_default.json` connects the selected backend to both raw
records. Reconsider the default only when correctness-gated interpreter and
YJIT measurements show no material regression across build, suite, repeated
validation, format, detailed errors, allocations, threads, and Ractors. A
GVL-free snapshot should be investigated only if a workload-specific profile
first shows that its complexity would address a measured bottleneck. The higher
priorities exposed here are incremental native-graph snapshots or shared graph
ownership, a genuinely generated C evaluator, direct indexed child/reference
tables, and per-call state that avoids a Ruby execution-object allocation.
