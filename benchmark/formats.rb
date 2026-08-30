# frozen_string_literal: true

require "benchmark/ips"
require "json"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "json_schema_validator"
require "json_schemer"

suite = File.join(
  root,
  "references",
  "JSON-Schema-Test-Suite",
  "tests",
  "draft2020-12",
  "optional",
  "format"
)
formats = %w[date date-time time]
groups = formats.flat_map do |format|
  file = File.join(suite, "#{format}.json")
  JSON.parse(File.read(file)).map do |group|
    {
      name: "#{format}.json: #{group.fetch("description")}",
      schema: group.fetch("schema"),
      tests: group.fetch("tests")
    }
  end
end
official_cases = groups.sum { |group| group.fetch(:tests).length }

adapters = {
  "json_schema_validator" => {
    build: lambda { |schema|
      JsonSchemaValidator::Validator.new(JsonSchemaValidator.compile(schema), format: true)
    },
    valid: ->(validator, data) { validator.valid?(data) }
  },
  "json_schemer" => {
    build: lambda { |schema|
      JSONSchemer.schema(schema, meta_schema: JSONSchemer.draft202012, format: true)
    },
    valid: ->(validator, data) { validator.valid?(data) }
  }
}

def build(groups, adapter)
  groups.map do |group|
    group.merge(validator: adapter.fetch(:build).call(group.fetch(:schema)))
  end
end

def validate_all(compiled, adapter)
  compiled.each do |group|
    validator = group.fetch(:validator)
    group.fetch(:tests).each { |test| adapter.fetch(:valid).call(validator, test.fetch("data")) }
  end
end

prepared = adapters.transform_values { |adapter| build(groups, adapter) }
primary = prepared.fetch("json_schema_validator")
primary_wrong = primary.sum do |group|
  group.fetch(:tests).count do |test|
    adapters.fetch("json_schema_validator").fetch(:valid).call(group.fetch(:validator), test.fetch("data")) != test.fetch("valid")
  end
end
raise "json_schema_validator produced #{primary_wrong} wrong results" unless primary_wrong.zero?

excluded = []
selected_tests = groups.each_index.map do |group_index|
  groups.fetch(group_index).fetch(:tests).select do |test|
    wrong = adapters.filter_map do |name, adapter|
      validator = prepared.fetch(name).fetch(group_index).fetch(:validator)
      name if adapter.fetch(:valid).call(validator, test.fetch("data")) != test.fetch("valid")
    end

    excluded << [groups.fetch(group_index).fetch(:name), test.fetch("description"), wrong] unless wrong.empty?
    wrong.empty?
  end
end

groups = groups.each_with_index.map { |group, index| group.merge(tests: selected_tests.fetch(index)) }
cases = groups.sum { |group| group.fetch(:tests).length }
compiled = prepared.to_h do |name, compiled_groups|
  selected = compiled_groups.each_with_index.map do |group, index|
    group.merge(tests: selected_tests.fetch(index))
  end

  [name, selected]
end

puts "JSON-Schema-Test-Suite Draft 2020-12 date, date-time, and time formats"
puts "#{groups.length} schemas, #{cases}/#{official_cases} mutually correct validation cases"
unless excluded.empty?
  puts "Excluded #{excluded.length} cases with product result differences:"
  excluded.each do |group, test, names|
    puts "  #{group} / #{test} (#{names.join(", ")})"
  end
end

time = Float(ENV.fetch("BENCHMARK_TIME", "5"))
warmup = Float(ENV.fetch("BENCHMARK_WARMUP", "2"))
only = ENV["BENCHMARK_ONLY"]

if only.nil? || only == "build"
  Benchmark.ips do |benchmark|
    benchmark.config(time: time, warmup: warmup)
    adapters.each do |name, adapter|
      benchmark.report("#{name} build") { build(groups, adapter) }
    end
    benchmark.compare!
  end
end

if only.nil? || only == "suite"
  Benchmark.ips do |benchmark|
    benchmark.config(time: time, warmup: warmup)
    adapters.each do |name, adapter|
      benchmark.report("#{name} suite") { validate_all(build(groups, adapter), adapter) }
    end
    benchmark.compare!
  end
end

if only.nil? || only == "validate"
  Benchmark.ips do |benchmark|
    benchmark.config(time: time, warmup: warmup)
    adapters.each do |name, adapter|
      benchmark.report("#{name} validate") { validate_all(compiled.fetch(name), adapter) }
    end
    benchmark.compare!
  end
end
