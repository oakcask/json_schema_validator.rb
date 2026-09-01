# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "the VM backend" do
  it "compiles schema nodes into frozen instruction streams", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile(
      {"type" => "object", "properties" => {"name" => {"type" => "string"}}},
      backend: :vm
    )
    evaluator = validator.instance_variable_get(:@evaluator)
    program = evaluator.instance_variable_get(:@root)
    object_rules = program.code.assoc(:object).fetch(1)

    expect(program.code.map(&:first)).to eq(%i[type_object object])
    expect(program.code).to be_frozen
    expect(program.code).to all(be_frozen)
    expect(object_rules.properties.fetch("name").code.map(&:first)).to eq([:type_string])
  end

  it "executes the compiled program after the source schema changes", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "integer"}
    validator = Schemurai.compile(schema, backend: :vm)
    schema.clear

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?(1.5)).to be(false)
    expect(validator.validate(1.5).errors.map(&:keyword)).to eq(["type"])
  end

  it "snapshots nested mutable operands without freezing the source schema", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "type" => ["object"],
      "required" => [+"kind", +"value"],
      "properties" => {
        "kind" => {"enum" => [{"tag" => ["fixed"]}]},
        "value" => {"const" => {"tag" => ["fixed"]}},
        "name" => {"type" => "string", "pattern" => +"^fixed$"}
      },
      "dependentRequired" => {"kind" => ["name"]}
    }
    enum_value = schema.dig("properties", "kind", "enum", 0, "tag")
    const_value = schema.dig("properties", "value", "const", "tag")
    pattern = schema.dig("properties", "name", "pattern")
    required_kind = schema.fetch("required").first
    validator = Schemurai.compile(schema, backend: :vm)

    valid = {"kind" => {"tag" => ["fixed"]}, "value" => {"tag" => ["fixed"]}, "name" => "fixed"}
    invalid = [
      [],
      {},
      valid.merge("kind" => {"tag" => ["changed"]}),
      valid.merge("value" => {"tag" => ["changed"]}),
      valid.merge("name" => "changed"),
      valid.except("kind"),
      valid.except("name")
    ]
    expect(validator.valid?(valid)).to be(true)
    expect(invalid.map { |instance| validator.valid?(instance) }).to all(be(false))

    schema.fetch("type") << "array"
    required_kind.replace("value")
    enum_value.replace(["changed"])
    const_value.replace(["changed"])
    pattern.replace(".*")
    schema.dig("dependentRequired", "kind").clear

    expect(validator.valid?(valid)).to be(true)
    expect(invalid.map { |instance| validator.valid?(instance) }).to all(be(false))
    expect(schema.fetch("type")).not_to be_frozen
  end

  it "keeps a resolved external program stable after its source changes", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    external = {"type" => ["integer"]}
    registry = Schemurai::SchemaRegistry.new(schemas: {"urn:external" => external}, backend: :vm)
    validator = registry.compile({"$ref" => "urn:external"})

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?("text")).to be(false)

    external.fetch("type") << "string"

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?("text")).to be(false)
  end
end
