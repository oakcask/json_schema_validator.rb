# frozen_string_literal: true

require "benchmark/ips"
require "json"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "schemurai"
require "json-schema"
require "json_schemer"

suite = File.join(root, "references", "JSON-Schema-Test-Suite", "tests", "draft6")
files = Dir[File.join(suite, "*.json")].sort
files.reject! { |file| File.basename(file) == "refRemote.json" }

suite_groups = files.flat_map do |file|
  JSON.parse(File.read(file)).map do |group|
    {
      name: "#{File.basename(file)}: #{group.fetch("description")}",
      schema: group.fetch("schema"),
      tests: group.fetch("tests")
    }
  end
end
boolean_root_groups = suite_groups.count { |group| !group.fetch(:schema).is_a?(Hash) }
candidate_groups = suite_groups.select { |group| group.fetch(:schema).is_a?(Hash) }

draft6_meta_schema_uri = JSONSchemer::Draft6::BASE_URI.to_s.delete_suffix("#")
draft6_ref_resolver = lambda do |uri|
  return JSONSchemer::Draft6::SCHEMA if uri.to_s.delete_suffix("#") == draft6_meta_schema_uri

  raise JSONSchemer::UnknownRef, uri.to_s
end

adapters = {
  "lib" => {
    prepare_build: -> {},
    build: lambda { |schema|
      Schemurai.compile(schema)
    },
    valid: ->(validator, data) { validator.valid?(data) }
  },
  "json_schemer" => {
    prepare_build: -> {},
    build: lambda { |schema|
      JSONSchemer.schema(
        schema,
        meta_schema: JSONSchemer.draft6,
        ref_resolver: draft6_ref_resolver
      )
    },
    valid: ->(validator, data) { validator.valid?(data) }
  },
  "json-schema" => {
    prepare_build: -> { JSON::Validator.clear_cache },
    build: ->(schema) { JSON::Validator.new(schema, version: :draft6, parse_data: false) },
    valid: lambda { |validator, data|
      begin
        validator.validate(data)
        true
      rescue JSON::Schema::ValidationError
        false
      end
    }
  }
}

coverage = adapters.transform_values do
  {runnable_groups: 0, runnable_cases: 0, correct: 0, wrong: 0, exception_groups: 0, exception_cases: 0}
end

evaluated_groups = candidate_groups.map do |group|
  outcomes = adapters.to_h do |name, adapter|
    adapter.fetch(:prepare_build).call
    validator = adapter.fetch(:build).call(group.fetch(:schema))
    results = group.fetch(:tests).map do |test|
      adapter.fetch(:valid).call(validator, test.fetch("data")) == test.fetch("valid")
    end

    stats = coverage.fetch(name)
    stats[:runnable_groups] += 1
    stats[:runnable_cases] += results.length
    stats[:correct] += results.count(true)
    stats[:wrong] += results.count(false)
    [name, {wrong: results.count(false)}]
  rescue => exception
    stats = coverage.fetch(name)
    stats[:exception_groups] += 1
    stats[:exception_cases] += group.fetch(:tests).length
    [name, {exception: exception.class}]
  end

  [group, outcomes]
end
JSON::Validator.clear_cache

groups = evaluated_groups.filter_map do |group, outcomes|
  group if outcomes.values.all? { |outcome| !outcome.key?(:exception) && outcome.fetch(:wrong).zero? }
end
excluded = evaluated_groups.reject do |_group, outcomes|
  outcomes.values.all? { |outcome| !outcome.key?(:exception) && outcome.fetch(:wrong).zero? }
end
cases = groups.sum { |group| group.fetch(:tests).length }

puts "JSON-Schema-Test-Suite Draft 6"
puts "Performance subset: #{groups.length}/#{candidate_groups.length} hash-root schemas, #{cases} validation cases"
puts "Not candidates: refRemote.json and #{boolean_root_groups} boolean-root schema groups"
puts "Adapter coverage over #{candidate_groups.length} hash-root schemas:"
coverage.each do |name, stats|
  puts "  #{name}: #{stats.fetch(:runnable_groups)} runnable groups, " \
    "#{stats.fetch(:correct)}/#{stats.fetch(:runnable_cases)} correct, " \
    "#{stats.fetch(:wrong)} wrong, #{stats.fetch(:exception_groups)} exception groups " \
    "(#{stats.fetch(:exception_cases)} cases)"
end
puts "Excluded from performance: #{excluded.length} groups that raised or produced a wrong result"
excluded.each do |group, outcomes|
  reasons = outcomes.filter_map do |name, outcome|
    if outcome.key?(:exception)
      "#{name}: #{outcome.fetch(:exception)}"
    elsif outcome.fetch(:wrong).positive?
      "#{name}: #{outcome.fetch(:wrong)} wrong"
    end
  end
  puts "  #{group.fetch(:name)} (#{reasons.join(", ")})"
end

Benchmark.ips do |benchmark|
  benchmark.config(time: 5, warmup: 2)

  adapters.each do |name, adapter|
    benchmark.report("#{name} build") do
      adapter.fetch(:prepare_build).call
      groups.each { |group| adapter.fetch(:build).call(group.fetch(:schema)) }
    end
  end

  benchmark.compare!
end

JSON::Validator.clear_cache
compiled = adapters.transform_values do |adapter|
  groups.map do |group|
    group.merge(validator: adapter.fetch(:build).call(group.fetch(:schema)))
  end
end

compiled.each do |name, compiled_groups|
  adapter = adapters.fetch(name)
  correct = compiled_groups.sum do |group|
    group.fetch(:tests).count do |test|
      adapter.fetch(:valid).call(group.fetch(:validator), test.fetch("data")) == test.fetch("valid")
    end
  end
  raise "#{name} produced #{correct}/#{cases} expected results in the performance subset" unless correct == cases
end

Benchmark.ips do |benchmark|
  benchmark.config(time: 5, warmup: 2)

  compiled.each do |name, compiled_groups|
    adapter = adapters.fetch(name)
    benchmark.report("#{name} validate") do
      compiled_groups.each do |group|
        validator = group.fetch(:validator)
        group.fetch(:tests).each do |test|
          adapter.fetch(:valid).call(validator, test.fetch("data"))
        end
      end
    end
  end

  benchmark.compare!
end
