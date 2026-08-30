# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe JsonSchemaValidator do
  def format_assertion_schema(required, format:)
    meta_schema_uri = "https://example.test/format-assertion/#{required}"
    meta_schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => meta_schema_uri,
      "$vocabulary" => {
        "https://json-schema.org/draft/2020-12/vocab/core" => true,
        "https://json-schema.org/draft/2020-12/vocab/format-assertion" => required
      }
    }
    [{"$schema" => meta_schema_uri, "format" => format}, {meta_schema_uri => meta_schema}]
  end

  def expect_unsupported_format_to_be_rejected(required)
    schema, schemas = format_assertion_schema(required, format: "unknown")
    expect { described_class.compile(schema, schemas: schemas) }.to raise_error(
      JsonSchemaValidator::UnsupportedFormatError,
      /unsupported format "unknown" required by Format-Assertion vocabulary/
    )
  end

  it "keeps implementation constants private" do
    expected = %i[
      CompiledSchema Error ResolutionError Result SchemaRegistry UnsupportedFormatError ValidationError Validator
    ]
    expect(described_class.constants(false)).to match_array(expected)
  end

  it "exposes validator exceptions under one base error" do
    error_classes = [described_class::Error, described_class::ResolutionError, described_class::UnsupportedFormatError]
    expect(error_classes.map(&:superclass)).to eq([StandardError, described_class::Error, described_class::Error])
  end

  it "offers boolean and detailed validation APIs", :aggregate_failures do
    schema = {"type" => "integer", "minimum" => 2}

    expect(described_class.valid?(schema, 3)).to be(true)
    result = described_class.validate(schema, 1)
    expect(result).not_to be_valid
    expect(result.errors.first).to be_a(described_class::ValidationError).and have_attributes(keyword: "minimum", instance_path: "")
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

  it "resolves the format when compiling a reusable validator", :aggregate_failures do
    schema = {"format" => "date"}
    validator = described_class::Validator.new(described_class.compile(schema), format: true)
    schema["format"] = "unknown"

    expect(validator.valid?("2020-02-29")).to be(true)
    expect(validator.valid?("2021-02-29")).to be(false)
  end

  it "ignores unknown formats in best-effort assertion mode" do
    expect(described_class.valid?({"format" => "unknown"}, "anything", format: true)).to be(true)
  end

  it "rejects unknown formats while compiling a Format-Assertion schema", :aggregate_failures do
    [true, false].each { |required| expect_unsupported_format_to_be_rejected(required) }
  end
end
