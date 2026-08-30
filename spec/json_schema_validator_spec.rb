# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe JsonSchemaValidator do
  it "keeps implementation constants private" do
    expected = %i[CompiledSchema Error ResolutionError Result SchemaRegistry Validator]
    expect(described_class.constants(false)).to match_array(expected)
  end

  it "offers boolean and detailed validation APIs", :aggregate_failures do
    schema = {"type" => "integer", "minimum" => 2}

    expect(described_class.valid?(schema, 3)).to be(true)
    result = described_class.validate(schema, 1)
    expect(result).not_to be_valid
    expect(result.errors.first.to_h).to include(keyword: "minimum", instance_path: "")
  end

  it "resolves registered external schemas", :aggregate_failures do
    schema = {"$ref" => "https://example.test/integer"}
    schemas = {"https://example.test/integer" => {"type" => "integer"}}

    expect(described_class.valid?(schema, 1, schemas: schemas)).to be(true)
    expect(described_class.valid?(schema, "1", schemas: schemas)).to be(false)
  end

  it "validates repeatedly with a compiled schema", :aggregate_failures do
    compiled = described_class.compile("type" => "integer")
    validator = described_class::Validator.new(compiled)

    expect(validator.valid?(1)).to be(true)
    expect(validator.valid?("1")).to be(false)
    expect(validator.validate("1")).not_to be_valid
  end

  it "requires Validator schemas to be compiled" do
    expect { described_class::Validator.new("type" => "integer") }
      .to raise_error(ArgumentError, /SchemaRegistry#compile/)
  end

  it "shares registered schemas between compiled schemas" do
    registry = described_class::SchemaRegistry.new(schemas: {"urn:integer" => {"type" => "integer"}})
    validators = 2.times.map { described_class::Validator.new(registry.compile("$ref" => "urn:integer")) }
    results = [validators.first.valid?(1), validators.last.valid?("1")]
    expect(results).to eq([true, false])
  end

  it "keeps format as an annotation by default" do
    expect(described_class.valid?({"format" => "email"}, "not an email")).to be(true)
  end

  it "optionally asserts supported formats", :aggregate_failures do
    expect(described_class.valid?({"format" => "date"}, "2020-02-29", format: true)).to be(true)
    expect(described_class.valid?({"format" => "date"}, "2021-02-29", format: true)).to be(false)

    result = described_class.validate({"format" => "time"}, "24:00:00Z", format: true)
    expect(result).not_to be_valid
    expect(result.errors.first.to_h).to include(keyword: "format", schema_path: "/format")
  end

  it "supports format assertions with a reusable validator", :aggregate_failures do
    validator = described_class::Validator.new(described_class.compile("format" => "date-time"), format: true)

    expect(validator.valid?("1963-06-19T08:30:06Z")).to be(true)
    expect(validator.valid?("1963-06-19 08:30:06Z")).to be(false)
  end

  it "ignores unknown formats in best-effort assertion mode" do
    expect(described_class.valid?({"format" => "unknown"}, "anything", format: true)).to be(true)
  end
end
