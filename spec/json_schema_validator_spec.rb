# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe JsonSchemaValidator do
  it "keeps implementation constants private" do
    expect(described_class.constants(false)).to contain_exactly(:Error, :ResolutionError, :Result, :Validator)
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

  it "keeps format as an annotation by default" do
    expect(described_class.valid?({"format" => "email"}, "not an email")).to be(true)
  end
end
