# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "validation error messages" do
  let(:cases) do
    [
      [false, nil, {}, "value is not allowed by this schema"],
      [{"type" => "string"}, 1, {}, 'value has type "integer", but must have type "string"'],
      [{"enum" => [1, 2]}, 3, {}, "value must equal one of the values defined by `enum`"],
      [{"const" => "yes"}, "no", {}, "value must equal the value defined by `const`"],
      [{"maximum" => 2.5}, 3, {}, "number must be less than or equal to 2.5"],
      [{"minimum" => 2}, 1, {}, "number must be greater than or equal to 2"],
      [{"exclusiveMaximum" => 2}, 2, {}, "number must be less than 2"],
      [{"exclusiveMinimum" => 2}, 2, {}, "number must be greater than 2"],
      [{"multipleOf" => 2.5}, 3, {}, "number must be a multiple of 2.5"],
      [{"maxLength" => 2}, "abc", {}, "string must contain at most 2 characters (found 3)"],
      [{"minLength" => 2}, "a", {}, "string must contain at least 2 characters (found 1)"],
      [{"pattern" => "^a+$"}, "bbb", {}, 'string must match pattern "^a+$"'],
      [{"format" => "date"}, "invalid", {format: true}, "string must match the date format"],
      [{"contentEncoding" => "base64"}, "%%%", {content: true}, "string must be valid base64"],
      [{"contentMediaType" => "application/json"}, "{", {content: true}, "string must contain valid JSON"],
      [{"maxItems" => 2}, [1, 2, 3], {}, "array must contain at most 2 items (found 3)"],
      [{"minItems" => 2}, [1], {}, "array must contain at least 2 items (found 1)"],
      [{"uniqueItems" => true}, [1, 1], {}, "array items must be unique"],
      [
        {"contains" => {"type" => "integer"}, "minContains" => 2},
        [1, "x"],
        {},
        "array must contain at least 2 items matching `contains` (found 1)"
      ],
      [{"maxProperties" => 1}, {"a" => 1, "b" => 2}, {}, "object must contain at most 1 property (found 2)"],
      [{"minProperties" => 2}, {"a" => 1}, {}, "object must contain at least 2 properties (found 1)"],
      [{"required" => ["name"]}, {}, {}, 'object is missing required property "name"'],
      [
        {"dependencies" => {"credit_card" => ["billing_address"]}},
        {"credit_card" => 1},
        {},
        'property "billing_address" is required when property "credit_card" is present'
      ],
      [{"anyOf" => [{"type" => "integer"}, {"type" => "string"}]}, true, {}, "value must match at least one subschema"],
      [{"oneOf" => [{"type" => "number"}, {"type" => "integer"}]}, 1, {}, "value must match exactly one subschema (matched 2)"],
      [{"not" => {}}, nil, {}, "value must not match the subschema"]
    ]
  end

  def messages_for(schema, instance, options)
    %i[ruby vm].map do |backend|
      Schemurai.validate(schema, instance, **options, backend: backend).errors.map(&:message)
    end
  end

  it "uses specific, consistent messages in every backend", :aggregate_failures do
    cases.each do |schema, instance, options, expected|
      expect(messages_for(schema, instance, options)).to eq([[expected], [expected]]), -> { "schema: #{schema.inspect}" }
    end
  end

  it "does not build messages for errors discarded during trial evaluation" do
    formatter = Schemurai.const_get(:Internal).const_get(:ErrorMessage)
    allow(formatter).to receive(:pattern).and_call_original
    schema = {"anyOf" => [{"pattern" => "^a$"}, {"pattern" => "^b$"}]}

    %i[ruby vm].each { |backend| Schemurai.validate(schema, "c", backend: backend) }

    expect(formatter).not_to have_received(:pattern)
  end
end
