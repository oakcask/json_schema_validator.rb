# frozen_string_literal: true

require "json"
require "rbconfig"
require "schemurai"

iterations = Integer(ENV.fetch("ITERATIONS", "1000000"))
compile_iterations = Integer(ENV.fetch("COMPILE_ITERATIONS", "10000"))
schema = {"type" => "integer"}
ruby_validator = Schemurai.compile(schema, backend: :ruby)
native_validator = Schemurai.compile(schema.dup, backend: :native)
instances = [1, 1.0, 1.5, "1"].freeze

measure = lambda do |validator|
  10_000.times { |index| validator.valid?(instances[index % instances.length]) }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times { |index| validator.valid?(instances[index % instances.length]) }
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

measure_compile = lambda do |backend|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  compile_iterations.times { Schemurai.compile(schema.dup, backend: backend) }
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

samples = 5.times.map do
  {
    "ruby_compile_seconds" => measure_compile.call(:ruby),
    "native_compile_seconds" => measure_compile.call(:native),
    "ruby_validation_seconds" => measure.call(ruby_validator),
    "native_validation_seconds" => measure.call(native_validator)
  }
end

puts JSON.pretty_generate(
  "benchmark" => "native_type_slice_repeated_validation",
  "ruby_version" => RUBY_DESCRIPTION,
  "platform" => RUBY_PLATFORM,
  "compiler" => RbConfig::CONFIG["CC_VERSION_MESSAGE"],
  "yjit" => RubyVM::YJIT.enabled?,
  "iterations_per_sample" => iterations,
  "compilations_per_sample" => compile_iterations,
  "warmup_iterations" => 10_000,
  "instances" => instances,
  "samples" => samples
)
