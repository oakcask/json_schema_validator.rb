# frozen_string_literal: true

require "benchmark/ips"
require "json"

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(ENV.fetch("JSON_SCHEMA_VALIDATOR_LIB", File.join(root, "lib")))

require "schemurai"

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
      name: "#{File.basename(file)}: #{group.fetch("description")}",
      schema: group.fetch("schema"),
      tests: group.fetch("tests"),
      content: content
    }
  end
end
cases = groups.sum { |group| group.fetch(:tests).length }

def build(groups, remotes)
  registry = Schemurai::SchemaRegistry.new(schemas: remotes)
  groups.map do |group|
    group.merge(
      validator: registry.compile(group.fetch(:schema), content: group.fetch(:content))
    )
  end
end

def validate_all(compiled)
  compiled.each do |group|
    validator = group.fetch(:validator)
    group.fetch(:tests).each { |test| validator.valid?(test.fetch("data")) }
  end
end

compiled = build(groups, remotes)
wrong = compiled.sum do |group|
  group.fetch(:tests).count do |test|
    group.fetch(:validator).valid?(test.fetch("data")) != test.fetch("valid")
  end
end
raise "validator produced #{wrong} wrong results" unless wrong.zero?

puts "JSON-Schema-Test-Suite Draft 7"
puts "#{groups.length} schemas, #{cases} validation cases"

time = Float(ENV.fetch("BENCHMARK_TIME", "5"))
warmup = Float(ENV.fetch("BENCHMARK_WARMUP", "2"))
only = ENV["BENCHMARK_ONLY"]

if only.nil? || only == "build"
  Benchmark.ips do |benchmark|
    benchmark.config(time: time, warmup: warmup)
    benchmark.report("lib build") { build(groups, remotes) }
  end
end

if only.nil? || only == "suite"
  Benchmark.ips do |benchmark|
    benchmark.config(time: time, warmup: warmup)
    benchmark.report("lib suite") { validate_all(build(groups, remotes)) }
  end
end

if only.nil? || only == "validate"
  Benchmark.ips do |benchmark|
    benchmark.config(time: time, warmup: warmup)
    benchmark.report("lib validate") { validate_all(compiled) }
  end
end
