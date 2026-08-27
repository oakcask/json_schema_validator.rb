# frozen_string_literal: true

require "benchmark/ips"
require "json"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))

require "json_schema_validator"
require "json-schema"
require "json_schemer"

suite = File.join(root, "references", "JSON-Schema-Test-Suite", "tests", "draft6")
files = Dir[File.join(suite, "*.json")].sort
files.reject! { |file| File.basename(file) == "refRemote.json" }

candidate_groups = files.flat_map do |file|
  JSON.parse(File.read(file)).filter_map do |group|
    next unless group.fetch("schema").is_a?(Hash)

    {
      name: "#{File.basename(file)}: #{group.fetch("description")}",
      schema: group.fetch("schema"),
      tests: group.fetch("tests")
    }
  end
end

draft6_meta_schema_uri = JSONSchemer::Draft6::BASE_URI.to_s.delete_suffix("#")
draft6_ref_resolver = lambda do |uri|
  return JSONSchemer::Draft6::SCHEMA if uri.to_s.delete_suffix("#") == draft6_meta_schema_uri

  raise JSONSchemer::UnknownRef, uri.to_s
end

adapters = {
  "lib" => {
    compile: ->(schema) { JsonSchemaValidator::Validator.new(schema) },
    valid: ->(validator, data) { validator.valid?(data) }
  },
  "json_schemer" => {
    compile: lambda { |schema|
      JSONSchemer.schema(
        schema,
        meta_schema: JSONSchemer.draft6,
        ref_resolver: draft6_ref_resolver
      )
    },
    valid: ->(validator, data) { validator.valid?(data) }
  },
  "json-schema" => {
    compile: ->(schema) { JSON::Validator.new(schema, version: :draft6) },
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

excluded = []
groups = candidate_groups.filter_map do |group|
  error = adapters.find do |name, adapter|
    validator = adapter.fetch(:compile).call(group.fetch(:schema))
    group.fetch(:tests).each do |test|
      adapter.fetch(:valid).call(validator, test.fetch("data"))
    end
    false
  rescue => exception
    excluded << [group.fetch(:name), name, exception.class]
    true
  end

  group unless error
end
JSON::Validator.clear_cache

cases = groups.sum { |group| group.fetch(:tests).length }

compiled = adapters.transform_values do |adapter|
  groups.map do |group|
    group.merge(validator: adapter.fetch(:compile).call(group.fetch(:schema)))
  end
end

puts "JSON-Schema-Test-Suite Draft 6"
puts "#{groups.length} schemas, #{cases} validation cases"
puts "Excluded: refRemote.json, boolean schemas, and #{excluded.length} incompatible schema groups"
excluded.each { |group, adapter, error| puts "  #{group} (#{adapter}: #{error})" }

compiled.each do |name, compiled_groups|
  adapter = adapters.fetch(name)
  correct = compiled_groups.sum do |group|
    group.fetch(:tests).count do |test|
      adapter.fetch(:valid).call(group.fetch(:validator), test.fetch("data")) == test.fetch("valid")
    end
  end
  puts "#{name}: #{correct}/#{cases} expected results"
end

Benchmark.ips do |benchmark|
  benchmark.config(time: 5, warmup: 2)

  adapters.each do |name, adapter|
    benchmark.report("#{name} compile") do
      groups.each { |group| adapter.fetch(:compile).call(group.fetch(:schema)) }
    end
  end

  benchmark.compare!
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
