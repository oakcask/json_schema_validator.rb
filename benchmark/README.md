# Performance Benchmark

`draft7.rb` measures this implementation against all 1,045 supported required
and optional cases from the official Draft 7 suite. It verifies every expected
result before measuring validator construction, end-to-end suite execution, and
validation with constructed validators.

Run the current implementation with:

```sh
bundle exec ruby benchmark/draft7.rb
```

Measure allocated objects for the same build, end-to-end suite, and validation
workloads with:

```sh
bundle exec ruby benchmark/allocations.rb
```

Set `BENCHMARK_ITERATIONS` to control the number of measured iterations. The
default is 20. The script warms constructed validators before measuring and
uses `GC.stat(:total_allocated_objects)`, so it requires no profiler gem.

To reproduce the comparison, set `JSON_SCHEMA_VALIDATOR_LIB` to the `lib`
directory of a checkout at the baseline revision and run the same command.

## Product Comparison

`draft6.rb` has a different purpose: it compares this product in speed, with
`json_schemer` and `json-schema` over the mutually supported Draft 6 subset.

`draft2019_09.rb` and `draft2020_12.rb` compare this product with `json_schemer`
over all supported required and optional cases for their respective dialects.
Both scripts verify every expected result before measuring build, end-to-end
suite, and validation performance.

```sh
bundle exec ruby benchmark/draft2019_09.rb
bundle exec ruby benchmark/draft2020_12.rb
```

Set `BENCHMARK_ONLY` to `build`, `suite`, or `validate` to run one workload.
This is useful for longer, lower-variance measurements:

```sh
BENCHMARK_ONLY=suite BENCHMARK_TIME=15 BENCHMARK_WARMUP=3 \
  bundle exec ruby benchmark/draft2020_12.rb
```

To compare another checkout, point `JSON_SCHEMA_VALIDATOR_LIB` at its `lib`
directory while running the same script and settings:

```sh
JSON_SCHEMA_VALIDATOR_LIB=../baseline/lib BENCHMARK_ONLY=suite \
  BENCHMARK_TIME=15 BENCHMARK_WARMUP=3 \
  bundle exec ruby benchmark/draft2020_12.rb
```
