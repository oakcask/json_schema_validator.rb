# Performance baseline

`draft7.rb` measures this implementation against all 1,043 supported required
and optional cases from the official Draft 7 suite. It verifies every expected
result before measuring validator construction, end-to-end suite execution, and
validation with constructed validators.

Run the current implementation with:

```sh
bundle exec ruby benchmark/draft7.rb
```

To reproduce the comparison, set `JSON_SCHEMA_VALIDATOR_LIB` to the `lib`
directory of a checkout at the baseline revision and run the same command.

`draft6.rb` has a different purpose: it compares this product with
`json_schemer` and `json-schema` over the mutually supported Draft 6 subset. Its
numbers are not used for the baseline improvement percentages above.
