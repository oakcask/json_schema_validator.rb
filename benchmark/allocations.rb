# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "json_schema_validator"

suite_root = File.join(root, "references", "JSON-Schema-Test-Suite")
remote_root = File.join(suite_root, "remotes")
remotes = Dir[File.join(remote_root, "**", "*.json")].to_h do |file|
  relative = file.delete_prefix("#{remote_root}/")
  ["http://localhost:1234/#{relative}", JSON.parse(File.read(file))]
end

required_files = Dir[File.join(suite_root, "tests", "draft7", "*.json")]
optional_files = Dir[File.join(suite_root, "tests", "draft7", "optional", "*.json")]

groups = (required_files.sort + optional_files.sort).flat_map do |file|
  content = file.include?("/optional/")
  JSON.parse(File.read(file)).map do |group|
    {
      schema: group.fetch("schema"),
      tests: group.fetch("tests"),
      content: content
    }
  end
end

def build(groups, remotes)
  groups.map do |group|
    group.merge(
      validator: JsonSchemaValidator::Validator.new(
        group.fetch(:schema),
        schemas: remotes,
        content: group.fetch(:content)
      )
    )
  end
end

def validate_all(compiled)
  compiled.each do |group|
    validator = group.fetch(:validator)
    group.fetch(:tests).each { |test| validator.valid?(test.fetch("data")) }
  end
end

def allocations(iterations)
  GC.start
  before = GC.stat(:total_allocated_objects)
  iterations.times { yield }
  GC.stat(:total_allocated_objects) - before
end

iterations = Integer(ENV.fetch("BENCHMARK_ITERATIONS", "20"))
compiled = build(groups, remotes)
wrong = compiled.sum do |group|
  group.fetch(:tests).count do |test|
    group.fetch(:validator).valid?(test.fetch("data")) != test.fetch("valid")
  end
end
raise "validator produced #{wrong} wrong results" unless wrong.zero?

validate_all(compiled)

measurements = {
  "lib build" => allocations(iterations) { build(groups, remotes) },
  "lib suite" => allocations(iterations) { validate_all(build(groups, remotes)) },
  "lib validate" => allocations(iterations) { validate_all(compiled) }
}

puts "JSON-Schema-Test-Suite Draft 7 allocations"
puts "#{groups.length} schemas, #{groups.sum { |group| group.fetch(:tests).length }} validation cases"
puts "#{iterations} iterations"
measurements.each do |name, total|
  puts "%12s %10.1f objects/iteration (%d total)" % [name, total.fdiv(iterations), total]
end
