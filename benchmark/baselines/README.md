# Ruby oracle baselines

Run `ruby benchmark/oracle_baseline.rb` with the interpreter and
`ruby --yjit benchmark/oracle_baseline.rb` with YJIT. Records retain every raw
sample, Ruby/compiler identity, iteration counts, correctness digest, and Ruby
allocation counts. They are correctness and regression references, not fixed
performance promises across machines.
