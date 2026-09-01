# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "backend selection" do
  it "makes selection and actual identity observable", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    registry = Schemurai::SchemaRegistry.new(backend: :ruby)
    validator = registry.compile(true)
    requested = ENV.fetch("SCHEMURAI_BACKEND", "ruby").to_sym
    selected = (requested == :default) ? :ruby : requested

    expect(Schemurai.backend).to eq(selected)
    expect(registry.backend).to eq(:ruby)
    expect(validator.backend).to eq(:ruby)
  end

  it "selects the Ruby bytecode backend explicitly", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    registry = Schemurai::SchemaRegistry.new(backend: :bytecode)
    validator = registry.compile({"type" => "integer"})

    expect(registry.backend).to eq(:bytecode)
    expect(validator.backend).to eq(:bytecode)
    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?(1.5)).to be(false)
  end

  it "rejects removed and unknown backends", :aggregate_failures do
    %i[native unknown].each do |backend|
      expect { Schemurai.compile(true, backend: backend) }
        .to raise_error(Schemurai::Error, /unknown Schemurai backend/)
    end
  end
end
