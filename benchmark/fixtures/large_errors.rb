# frozen_string_literal: true

module LargeErrorFixtures
  module_function def groups(width:)
    properties = width.times.to_h { |index| ["p#{index}", {"type" => "integer"}] }
    object = width.times.to_h { |index| ["p#{index}", index] }

    [
      {
        "description" => "large object with a trailing error",
        "schema" => {
          "$schema" => "https://json-schema.org/draft/2020-12/schema",
          "type" => "object",
          "properties" => properties,
          "additionalProperties" => false
        },
        "tests" => [
          {
            "description" => "all properties are valid",
            "data" => object,
            "valid" => true
          },
          {
            "description" => "the last property has the wrong type",
            "data" => object.merge("p#{width - 1}" => "invalid"),
            "valid" => false
          }
        ]
      },
      {
        "description" => "large anyOf",
        "schema" => {
          "$schema" => "https://json-schema.org/draft/2020-12/schema",
          "anyOf" => Array.new(width) { {"type" => "integer"} }
        },
        "tests" => [
          {
            "description" => "the first alternative matches",
            "data" => 1,
            "valid" => true
          },
          {
            "description" => "all alternatives fail",
            "data" => "invalid",
            "valid" => false
          }
        ]
      }
    ]
  end
end
