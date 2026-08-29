# frozen_string_literal: true

require "benchmark/ips"
require "json"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "json_schema_validator"
require "json_schemer"

suite_root = File.join(root, "references", "JSON-Schema-Test-Suite")
remote_root = File.join(suite_root, "remotes")
remotes = Dir[File.join(remote_root, "**", "*.json")].to_h do |file|
  relative = file.delete_prefix("#{remote_root}/")
  ["http://localhost:1234/#{relative}", JSON.parse(File.read(file))]
end

required_files = Dir[File.join(suite_root, "tests", "draft2019-09", "*.json")]
optional_files = Dir[File.join(suite_root, "tests", "draft2019-09", "optional", "*.json")]

groups = (required_files.sort + optional_files.sort).flat_map do |file|
  content = file.include?("/optional/")
  JSON.parse(File.read(file)).map do |group|
    {
      name: "#{File.basename(file)}: #{group.fetch("description")}",
      schema: group.fetch("schema"),
      tests: group.fetch("tests"),
      content: content
    }
  end
end
cases = groups.sum { |group| group.fetch(:tests).length }

schemer_schemas = JSONSchemer::Draft201909::Meta::SCHEMAS.merge(
  JSONSchemer::Draft201909::BASE_URI => JSONSchemer::Draft201909::SCHEMA
)
remotes.each { |uri, schema| schemer_schemas[URI(uri)] = schema }
schemer_ref_resolver = schemer_schemas.to_proc

adapters = {
  "lib" => {
    build: lambda { |group|
      JsonSchemaValidator::Validator.new(
        group.fetch(:schema),
        schemas: remotes,
        content: group.fetch(:content)
      )
    },
    valid: ->(validator, data) { validator.valid?(data) }
  },
  "json_schemer" => {
    build: lambda { |group|
      JSONSchemer.schema(
        group.fetch(:schema),
        meta_schema: JSONSchemer.draft201909,
        ref_resolver: schemer_ref_resolver,
        regexp_resolver: "ecma"
      )
    },
    valid: ->(validator, data) { validator.valid?(data) }
  }
}

def build(groups, adapter)
  groups.map do |group|
    group.merge(validator: adapter.fetch(:build).call(group))
  end
end

def validate_all(compiled, adapter)
  compiled.each do |group|
    validator = group.fetch(:validator)
    group.fetch(:tests).each { |test| adapter.fetch(:valid).call(validator, test.fetch("data")) }
  end
end

compiled = adapters.to_h do |name, adapter|
  compiled_groups = build(groups, adapter)
  wrong = compiled_groups.sum do |group|
    group.fetch(:tests).count do |test|
      adapter.fetch(:valid).call(group.fetch(:validator), test.fetch("data")) != test.fetch("valid")
    end
  end
  raise "#{name} produced #{wrong} wrong results" unless wrong.zero?

  [name, compiled_groups]
end

puts "JSON-Schema-Test-Suite Draft 2019-09"
puts "#{groups.length} schemas, #{cases} validation cases"

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
