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
