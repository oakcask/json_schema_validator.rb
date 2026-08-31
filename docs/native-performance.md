# Native production-default decision

The production default remains the Ruby backend. The native backend is strict
and fully selectable, but its final Workstream 9 measurements regress every
timed workload on the measured CRuby 4.0 Linux environment. Correctness and
package gates passed before these measurements were taken.

## Final measurements

The retained raw samples use CRuby 4.0.6, GCC 13.3, `-O3 -fno-fast-math`, five
samples, and the complete 1,877-case selected Draft 2020-12 corpus. Times below
are medians. A ratio greater than 1 means native took longer.

| Workload | Interpreter native/Ruby | YJIT native/Ruby |
| --- | ---: | ---: |
| Build 439 corpus schemas | 182.80x | 231.77x |
| Build and validate the corpus | 91.03x | 111.46x |
| Repeated boolean validation | 1.53x | 1.58x |
| Format assertion | 1.27x | 1.09x |
| Detailed errors | 1.65x | 1.84x |
| Four-thread validation | 22.98x | 37.24x |
| Four-Ractor validation | 1.73x | 2.19x |

Native repeated validation allocated 3.14 times as many Ruby objects in both
runs. The six-node typed-data graph occupied 568 bytes after compacting node
indexes, masks, and flags; its inferred node record is 80 bytes instead of 104.
These native bytes are not visible to Ruby allocation counters.

The complete evaluator measurements reinforce the lifecycle-complete vertical
slice checkpoints: expanding coverage did not reverse the original result.
Native removes some type-test dispatch, but graph import and Ruby-facing graph
views make compilation substantially more expensive, while a per-call execution
object preserves shareability at a validation cost. Releasing native as the
default would therefore impose broad regressions, especially with YJIT.

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
first shows that its complexity would address a measured bottleneck.
