# frozen_string_literal: true

require "spec_helper"
require_relative "../oracle/lib/runner"
require_relative "../oracle/lib/comparator"

RSpec.describe "the native evaluator" do
  around do |example|
    require "schemurai/native"
    example.run
  end

  it "does not instantiate or copy the Ruby evaluator" do
    ruby_evaluator = Schemurai.const_get(:Internal).const_get(:Evaluator)
    allow(ruby_evaluator).to receive(:new).and_raise("Ruby evaluator fallback")
    allow(ruby_evaluator).to receive(:dup).and_raise("Ruby evaluator copy")

    validator = Schemurai.compile({"type" => "integer"}, backend: :native)
    expect(validator.valid?(4)).to be(true)
    expect(validator.valid?(4.5)).to be(false)
  end

  it "matches the Ruby result stream for the complete catalog" do
    inputs = SchemuraiOracle::CaseCatalog.new.each_case
      .select { |record| record.classification == "selected" }
      .map { |record| {"catalog_case" => record.id} }
    ruby_runner = SchemuraiOracle::Runner.new(backend: :ruby)
    native_runner = SchemuraiOracle::Runner.new(backend: :native)
    ruby_records = inputs.map { |input| ruby_runner.run(input) }
    native_records = inputs.map { |input| native_runner.run(input) }
    comparison = SchemuraiOracle::Comparator.new.compare(ruby_records, native_records)

    expect(comparison).to be_empty
  end

  it "matches the recorded out-of-domain compatibility behavior", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    string_subclass = Class.new(String).new("text")
    singleton_string = +"x"
    singleton_string.define_singleton_method(:length) { 2 }
    numeric_class = Class.new(Numeric) { define_method(:to_s) { "2.5" } }
    hash_class = Class.new(Hash) do
      define_method(:each) do |&block|
        first = true
        super() do |key, value|
          delete("second") if first
          first = false
          block.call(key, value)
        end
      end
    end
    mutating_hash = hash_class["first", 1, "second", "bad"]
    key_hash_class = Class.new(Hash) { define_method(:key?) { |_key| false } }
    key_hash = key_hash_class.new
    key_hash["present"] = true

    expect(Schemurai.valid?({"type" => "string", "minLength" => 4}, string_subclass, backend: :native)).to be(true)
    expect(Schemurai.valid?({"type" => "string", "minLength" => 2}, singleton_string, backend: :native)).to be(true)
    expect(Schemurai.valid?({"type" => "number", "minimum" => 2}, numeric_class.new, backend: :native)).to be(true)
    expect(Schemurai.valid?({"properties" => {"first" => {"type" => "integer"}, "second" => {"type" => "integer"}}}, mutating_hash, backend: :native)).to be(true)
    expect(Schemurai.valid?({"required" => ["present"]}, key_hash, backend: :native)).to be(false)

    exceptional = Class.new(Numeric) { define_method(:finite?) { raise "finite failed" } }
    validator = Schemurai.compile({"type" => "integer"}, backend: :native)
    expect { validator.valid?(exceptional.new) }.to raise_error(RuntimeError, "finite failed")
    expect(validator.valid?(1)).to be(true)
  end

  it "normalizes invalid regular expressions like the Ruby evaluator", :aggregate_failures do
    validator = Schemurai.compile({"pattern" => "["}, backend: :native)

    expect(validator.valid?("value")).to be(false)
    expect(validator.validate("value").errors.map(&:message)).to eq(["invalid regular expression"])
  end

  it "survives compaction and runs from independent Ractor validators", :aggregate_failures do
    schema = {"$id" => "urn:native", "type" => "array", "items" => {"type" => "integer"}}
    validator = Schemurai.compile(schema, backend: :native)
    GC.compact
    expect(validator.valid?([1, 2, 3])).to be(true)

    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:native" => schema}, backend: :native)
    registry.make_shareable
    ractor = Ractor.new(registry) do |shared|
      local = shared.validator_for("urn:native")
      [local.backend, local.valid?([1]), local.valid?(["bad"])]
    end
    result = ractor.respond_to?(:value) ? ractor.value : ractor.take
    expect(result).to eq([:native, true, false])
  end
end
