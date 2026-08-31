# frozen_string_literal: true

require "digest"
require "json"
require "objspace"
require "rbconfig"
require "schemurai"
require_relative "../oracle/lib/case_catalog"
require_relative "fixtures/large_errors"

samples = Integer(ENV.fetch("BENCHMARK_SAMPLES", "5"))
suite_iterations = Integer(ENV.fetch("BENCHMARK_SUITE_ITERATIONS", "1"))
repeated_iterations = Integer(ENV.fetch("BENCHMARK_REPEATED_ITERATIONS", "10000"))
focused_iterations = Integer(ENV.fetch("BENCHMARK_FOCUSED_ITERATIONS", "1000"))
concurrency_workers = Integer(ENV.fetch("BENCHMARK_CONCURRENCY_WORKERS", "4"))
concurrency_iterations = Integer(ENV.fetch("BENCHMARK_CONCURRENCY_ITERATIONS", "2500"))
warmup_iterations = Integer(ENV.fetch("BENCHMARK_WARMUP_ITERATIONS", "100"))

configuration = {
  "samples" => samples,
  "suite_iterations_per_sample" => suite_iterations,
  "repeated_iterations_per_sample" => repeated_iterations,
  "focused_iterations_per_sample" => focused_iterations,
  "concurrency_workers" => concurrency_workers,
  "concurrency_iterations_per_worker" => concurrency_iterations,
  "warmup_iterations" => warmup_iterations,
  "measurement_method" => "Process.clock_gettime(CLOCK_MONOTONIC)",
  "allocation_method" => "GC.stat(:total_allocated_objects)",
  "native_memory_method" => "ObjectSpace.memsize_of(native typed-data graph)"
}
configuration.each do |name, value|
  next unless value.is_a?(Integer)

  raise "#{name} must be positive" unless value.positive?
end

catalog = SchemuraiOracle::CaseCatalog.new
records = catalog.each_case("draft2020-12").select { |record| record.classification == "selected" }
groups = records.group_by { |record| [JSON.generate(record.schema), JSON.generate(record.options)] }.values

main_schema = {
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
documents = [
  {"id" => 1, "name" => "valid", "tags" => %w[a b]},
  {"id" => 0, "name" => "x", "tags" => %w[a a]}
].freeze
format_schema = {
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "format" => "date"
}.freeze
format_instances = ["2024-02-29", "2023-02-29"].freeze
error_group = LargeErrorFixtures.groups(width: 100).first
error_schema = error_group.fetch("schema")
error_instance = error_group.fetch("tests").find { |test| !test.fetch("valid") }.fetch("data")

build_suite = lambda do |backend|
  registry = Schemurai::SchemaRegistry.new(schemas: catalog.remotes, backend: backend)
  groups.map do |group|
    first = group.first
    options = first.options.transform_keys(&:to_sym)
    [registry.compile(first.schema, **options), group]
  end
end

validate_suite = lambda do |compiled, detailed: false|
  compiled.sum do |validator, group|
    group.count do |record|
      result = detailed ? validator.validate(record.instance).valid? : validator.valid?(record.instance)
      result == record.expected
    end
  end
end

validators = %i[ruby native].to_h { |backend| [backend, Schemurai.compile(main_schema, backend: backend)] }
format_validators = %i[ruby native].to_h do |backend|
  [backend, Schemurai.compile(format_schema, format: true, backend: backend)]
end
error_validators = %i[ruby native].to_h { |backend| [backend, Schemurai.compile(error_schema, backend: backend)] }
compiled_suites = %i[ruby native].to_h { |backend| [backend, build_suite.call(backend)] }

expected_suite_cases = records.length
compiled_suites.each do |backend, compiled|
  correct = validate_suite.call(compiled)
  raise "#{backend} passed #{correct}/#{expected_suite_cases} selected cases" unless correct == expected_suite_cases
end

correctness = %i[ruby native].to_h do |backend|
  validator = validators.fetch(backend)
  format_validator = format_validators.fetch(backend)
  error_validator = error_validators.fetch(backend)
  [
    backend.to_s,
    {
      "boolean" => documents.map { |document| validator.valid?(document) },
      "format" => format_instances.map { |instance| format_validator.valid?(instance) },
      "errors" => error_validator.validate(error_instance).errors.map(&:to_h)
    }
  ]
end
raise "focused Ruby/native results differ" unless correctness.fetch("ruby") == correctness.fetch("native")

measure = lambda do |iterations, &block|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  iterations.times(&block)
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

measure_samples = lambda do |iterations, &block|
  samples.times.map { measure.call(iterations, &block) }
end

workloads = {}
%i[ruby native].each do |backend|
  validator = validators.fetch(backend)
  format_validator = format_validators.fetch(backend)
  error_validator = error_validators.fetch(backend)
  warmup_iterations.times do |index|
    validator.valid?(documents[index % documents.length])
    format_validator.valid?(format_instances[index % format_instances.length])
    error_validator.validate(error_instance)
  end

  workloads[backend.to_s] = {
    "build_seconds" => measure_samples.call(suite_iterations) { build_suite.call(backend) },
    "suite_seconds" => measure_samples.call(suite_iterations) do
      validate_suite.call(build_suite.call(backend))
    end,
    "repeated_validation_seconds" => measure_samples.call(repeated_iterations) do |index|
      validator.valid?(documents[index % documents.length])
    end,
    "format_seconds" => measure_samples.call(focused_iterations) do |index|
      format_validator.valid?(format_instances[index % format_instances.length])
    end,
    "detailed_error_seconds" => measure_samples.call(focused_iterations) do
      error_validator.validate(error_instance)
    end
  }
end

allocations = %i[ruby native].to_h do |backend|
  validator = validators.fetch(backend)
  GC.start
  before = GC.stat(:total_allocated_objects)
  repeated_iterations.times { |index| validator.valid?(documents[index % documents.length]) }
  total = GC.stat(:total_allocated_objects) - before
  [backend.to_s, {"iterations" => repeated_iterations, "total_objects" => total, "objects_per_iteration" => total.fdiv(repeated_iterations)}]
end

thread_seconds = %i[ruby native].to_h do |backend|
  worker_validators = Array.new(concurrency_workers) { Schemurai.compile(main_schema, backend: backend) }
  elapsed = samples.times.map do
    measure.call(1) do
      threads = worker_validators.map do |validator|
        Thread.new do
          concurrency_iterations.times.count do |index|
            validator.valid?(documents[index % documents.length]) == index.even?
          end
        end
      end
      correct = threads.sum(&:value)
      expected = concurrency_workers * concurrency_iterations
      raise "#{backend} thread workload passed #{correct}/#{expected}" unless correct == expected
    end
  end
  [backend.to_s, elapsed]
end

shareable_documents = Ractor.make_shareable(Marshal.load(Marshal.dump(documents)))
ractor_seconds = %i[ruby native].to_h do |backend|
  ractor_validators = if backend == :native
    Array.new(concurrency_workers) { Schemurai.compile(main_schema, backend: :native) }
  else
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:benchmark:main" => main_schema}, backend: :ruby)
    registry.make_shareable
    Array.new(concurrency_workers, registry)
  end
  elapsed = samples.times.map do
    workers = ractor_validators.map do |validator_source|
      Ractor.new(backend, validator_source, shareable_documents, concurrency_iterations) do |selected, source, inputs, iterations|
        validator = (selected == :native) ? source : source.validator_for("urn:benchmark:main")
        Ractor.receive
        iterations.times.count do |index|
          validator.valid?(inputs[index % inputs.length]) == index.even?
        end
      end
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    workers.each { |worker| worker.send(:start) }
    correct = workers.sum { |worker| worker.respond_to?(:value) ? worker.value : worker.take }
    measured = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    expected = concurrency_workers * concurrency_iterations
    raise "#{backend} Ractor workload passed #{correct}/#{expected}" unless correct == expected
    measured
  end
  [backend.to_s, elapsed]
end

native_evaluator = validators.fetch(:native).instance_variable_get(:@evaluator)
native_graph = native_evaluator.instance_variable_get(:@graph)
single_node_validator = Schemurai.compile({"type" => "integer"}, backend: :native)
single_node_evaluator = single_node_validator.instance_variable_get(:@evaluator)
single_node_graph = single_node_evaluator.instance_variable_get(:@graph)
graph_bytes = ObjectSpace.memsize_of(native_graph)
single_node_graph_bytes = ObjectSpace.memsize_of(single_node_graph)
node_record_bytes = (graph_bytes - single_node_graph_bytes).fdiv(native_graph.node_count - 1)
native_memory = {
  "graph_nodes" => native_graph.node_count,
  "graph_bytes" => graph_bytes,
  "single_node_graph_bytes" => single_node_graph_bytes,
  "inferred_node_record_bytes" => node_record_bytes
}

output = JSON.pretty_generate(
  "format_version" => 1,
  "benchmark" => "native_production_default",
  "ruby_version" => RUBY_VERSION,
  "ruby_description" => RUBY_DESCRIPTION,
  "platform" => RUBY_PLATFORM,
  "compiler" => RbConfig::CONFIG["CC_VERSION_MESSAGE"],
  "compiler_flags" => RbConfig::CONFIG.values_at("CFLAGS", "CPPFLAGS", "DLDFLAGS").compact.join(" "),
  "yjit" => defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?,
  "configuration" => configuration,
  "corpus" => {
    "dialect" => "draft2020-12",
    "selected_cases" => expected_suite_cases,
    "compiled_schemas" => groups.length,
    "focused_error_width" => 100
  },
  "correctness_sha256" => Digest::SHA256.hexdigest(JSON.generate(correctness.fetch("ruby"))),
  "workloads" => workloads,
  "allocations" => allocations,
  "native_memory" => native_memory,
  "concurrency" => {
    "thread_seconds" => thread_seconds,
    "ractor_seconds" => ractor_seconds
  }
)
output_path = ENV["BENCHMARK_OUTPUT"]
if output_path
  File.write(output_path, "#{output}\n")
else
  puts output
end
