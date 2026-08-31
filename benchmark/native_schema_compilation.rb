# frozen_string_literal: true

require "json"
require "objspace"
require "rbconfig"
require "schemurai"

compile_iterations = Integer(ENV.fetch("COMPILE_ITERATIONS", "1000"))
validation_iterations = Integer(ENV.fetch("ITERATIONS", "1000000"))

schema_factory = lambda do
  {
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "type" => "integer",
    "$defs" => 100.times.to_h do |index|
      ["node-#{index}", {"$id" => "urn:benchmark:node:#{index}", "type" => index.even? ? "integer" : "string"}]
    end
  }
end

measure_compile = lambda do |backend|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  compile_iterations.times { Schemurai.compile(schema_factory.call, backend: backend) }
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

native_validator = Schemurai.compile(schema_factory.call, backend: :native)
native_graph = native_validator.instance_variable_get(:@evaluator).instance_variable_get(:@graph)
measure_validation = lambda do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  validation_iterations.times { |index| native_validator.valid?(index) }
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

samples = 5.times.map do
  {
    "ruby_compile_seconds" => measure_compile.call(:ruby),
    "native_compile_seconds" => measure_compile.call(:native),
    "native_validation_seconds" => measure_validation.call
  }
end

puts JSON.pretty_generate(
  "benchmark" => "native_schema_compilation",
  "ruby_version" => RUBY_DESCRIPTION,
  "platform" => RUBY_PLATFORM,
  "compiler" => RbConfig::CONFIG["CC_VERSION_MESSAGE"],
  "yjit" => RubyVM::YJIT.enabled?,
  "nodes_per_graph" => native_graph.node_count,
  "native_graph_memsize" => ObjectSpace.memsize_of(native_graph),
  "compilations_per_sample" => compile_iterations,
  "validations_per_sample" => validation_iterations,
  "samples" => samples
)
