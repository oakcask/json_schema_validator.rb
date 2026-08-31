# Ruby oracle baselines

Run `ruby benchmark/oracle_baseline.rb` with the interpreter and
`ruby --yjit benchmark/oracle_baseline.rb` with YJIT. Records retain every raw
sample, Ruby/compiler identity, iteration counts, correctness digest, and Ruby
allocation counts. They are correctness and regression references, not fixed
performance promises across machines.

Native graph checkpoints are recorded by `benchmark/native_schema_compilation.rb`.
Run it once with the interpreter and once with `--yjit`; it reports full-graph
compilation, the typed-data allocation size exposed through `dsize`, and repeated
root validation without treating the measurements as release thresholds.

The `native-production-default-*` records are the final Workstream 9 evidence.
They retain both backends in each record, all required single-thread and
concurrency workloads, Ruby allocations, native typed-data memory, correctness
digest, compiler flags, warmup, configuration, and raw samples. Their selection
is recorded in `benchmark/production_default.json`.
