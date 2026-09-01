# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "the Ruby bytecode backend" do
  it "compiles schema nodes into frozen instruction streams", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    validator = Schemurai.compile(
      {"type" => "object", "properties" => {"name" => {"type" => "string"}}},
      backend: :bytecode
    )
    evaluator = validator.instance_variable_get(:@evaluator)
    program = evaluator.instance_variable_get(:@root)
    object_rules = program.code.assoc(:object).fetch(1)

    expect(program.code.map(&:first)).to eq(%i[type object])
    expect(program.code).to be_frozen
    expect(program.code).to all(be_frozen)
    expect(object_rules.fetch(:properties).fetch("name").code.map(&:first)).to eq([:type])
  end

  it "executes the compiled program after the source schema changes", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    schema = {"type" => "integer"}
    validator = Schemurai.compile(schema, backend: :bytecode)
    schema.clear

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?(1.5)).to be(false)
    expect(validator.validate(1.5).errors.map(&:keyword)).to eq(["type"])
  end
end
