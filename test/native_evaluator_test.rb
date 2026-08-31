# frozen_string_literal: true

require "rspec"
require "schemurai"
require "schemurai/native"

RSpec.describe "the complete native evaluator" do
  boolean_cases = [
    [{"enum" => [1, "one"]}, "one"],
    [{"const" => {"x" => [1]}}, {"x" => [1]}],
    [{"allOf" => [{"type" => "integer"}, {"minimum" => 1}]}, 2],
    [{"anyOf" => [{"type" => "string"}, {"minimum" => 1}]}, 2],
    [{"oneOf" => [{"type" => "number"}, {"type" => "integer"}]}, 1.5],
    [{"not" => {"type" => "string"}}, 2],
    [{"if" => {"type" => "integer"}, "then" => {"minimum" => 1}}, 2],
    [{"maximum" => 3, "multipleOf" => 0.5}, 2.5],
    [{"minLength" => 2, "pattern" => "^[a-z]+$"}, "ab"],
    [{"minItems" => 2, "uniqueItems" => true, "items" => {"type" => "integer"}}, [1, 2]],
    [{"required" => ["x"], "properties" => {"x" => {"type" => "integer"}}}, {"x" => 1}],
    [{"$defs" => {"value" => {"type" => "integer"}}, "$ref" => "#/$defs/value"}, 1]
  ].freeze

  it "matches boolean validation across every keyword category" do
    boolean_cases.each do |schema, instance|
      expect(Schemurai.valid?(schema, instance, backend: :native))
        .to eq(Schemurai.valid?(schema, instance, backend: :ruby))
    end
  end

  it "matches detailed errors and their ordering" do
    schema = {
      "type" => "object",
      "required" => %w[id name],
      "properties" => {
        "id" => {"type" => "integer", "minimum" => 1},
        "name" => {"type" => "string", "minLength" => 2}
      }
    }
    instance = {"id" => 0, "name" => "x"}

    ruby_errors = Schemurai.validate(schema, instance, backend: :ruby).errors.map(&:to_h)
    native_errors = Schemurai.validate(schema, instance, backend: :native).errors.map(&:to_h)
    expect(native_errors).to eq(ruby_errors)
  end

  it "matches annotation-driven unevaluated behavior" do
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "properties" => {"known" => true},
      "unevaluatedProperties" => false
    }

    expect(Schemurai.valid?(schema, {"known" => 1}, backend: :native)).to be(true)
    expect(Schemurai.valid?(schema, {"unknown" => 1}, backend: :native)).to be(false)
  end

  it "matches asserted format and content behavior" do
    format_schema = {"format" => "date"}
    content_schema = {"contentEncoding" => "base64", "contentMediaType" => "application/json"}

    expect(Schemurai.valid?(format_schema, "2024-02-29", format: true, backend: :native)).to be(true)
    expect(Schemurai.valid?(format_schema, "2023-02-29", format: true, backend: :native)).to be(false)
    expect(Schemurai.valid?(content_schema, "eyJ4IjoxfQ==", content: true, backend: :native)).to be(true)
    expect(Schemurai.valid?(content_schema, "not base64", content: true, backend: :native)).to be(false)
  end

  it "does not invoke the Ruby evaluator on forced-native paths" do
    ruby_evaluator = Schemurai.const_get(:Internal)::Evaluator
    allow(ruby_evaluator).to receive(:new).and_raise("Ruby evaluator fallback")

    validator = Schemurai.compile({"minimum" => 1}, backend: :native)
    expect(validator.valid?(2)).to be(true)
    expect(validator.validate(0).valid?).to be(false)
  end
end
