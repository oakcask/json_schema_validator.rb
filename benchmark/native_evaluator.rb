# frozen_string_literal: true

require "json"
require "rbconfig"
require "schemurai"

iterations = Integer(ENV.fetch("ITERATIONS", "100000"))
schema = {
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "type" => "object",
  "properties" => {
    "id" => {"type" => "integer", "minimum" => 1},
    "name" => {"type" => "string", "minLength" => 2, "pattern" => "^[a-z]+$"},
    "tags" => {"type" => "array", "uniqueItems" => true, "items" => {"type" => "string"}}
  },
  "required" => %w[id name tags],
  "additionalProperties" => false
}
instances = [
  {"id" => 1, "name" => "valid", "tags" => %w[a b]},
  {"id" => 0, "name" => "x", "tags" => %w[a a]}
].freeze
validators = {
  "ruby" => Schemurai.compile(schema, backend: :ruby),
  "native" => Schemurai.compile(schema, backend: :native)
}

measure = lambda do |validator, detailed:|
  1_000.times { |index| validator.valid?(instances[index % instances.length]) }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times do |index|
    instance = instances[index % instances.length]
    detailed ? validator.validate(instance) : validator.valid?(instance)
  end
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

samples = 5.times.map do
  validators.to_h do |name, validator|
    [
      name,
      {
        "boolean_seconds" => measure.call(validator, detailed: false),
        "detailed_seconds" => measure.call(validator, detailed: true)
      }
    ]
  end
end

puts JSON.pretty_generate(
  "benchmark" => "native_complete_evaluator",
  "ruby_version" => RUBY_DESCRIPTION,
  "platform" => RUBY_PLATFORM,
  "compiler" => RbConfig::CONFIG["CC_VERSION_MESSAGE"],
  "yjit" => RubyVM::YJIT.enabled?,
  "iterations_per_sample" => iterations,
  "warmup_iterations" => 1_000,
  "samples" => samples
)
