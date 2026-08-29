# frozen_string_literal: true

require_relative "draft7"

module JsonSchemaValidator
  module Internal
    module Dialects
      module Draft201909
        META_SCHEMA_URI = "https://json-schema.org/draft/2019-09/schema"

        KEYWORDS = Draft7::DIALECT.keywords.merge(
          "$defs" => Dialect::Keyword.new(mask: 0, subschema_shape: :map),
          "$recursiveRef" => Dialect::Keyword.new(mask: Dialect::COMBINER),
          "dependentSchemas" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :map),
          "dependentRequired" => Dialect::Keyword.new(mask: Dialect::OBJECT),
          "minContains" => Dialect::Keyword.new(mask: Dialect::ARRAY),
          "maxContains" => Dialect::Keyword.new(mask: Dialect::ARRAY),
          "unevaluatedItems" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single),
          "unevaluatedProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :single),
          "contentSchema" => Dialect::Keyword.new(mask: Dialect::STRING, subschema_shape: :single)
        ).freeze

        META_SCHEMA = {
          "$schema" => META_SCHEMA_URI,
          "$id" => META_SCHEMA_URI,
          "$recursiveAnchor" => true,
          "type" => ["object", "boolean"],
          "properties" => {
            "$defs" => {"type" => "object", "additionalProperties" => {"$recursiveRef" => "#"}},
            "definitions" => {"type" => "object", "additionalProperties" => {"$recursiveRef" => "#"}},
            "type" => {
              "anyOf" => [
                {"enum" => ["null", "boolean", "object", "array", "number", "integer", "string"]},
                {
                  "type" => "array",
                  "items" => {"enum" => ["null", "boolean", "object", "array", "number", "integer", "string"]},
                  "minItems" => 1,
                  "uniqueItems" => true
                }
              ]
            },
            "minLength" => {"type" => "integer", "minimum" => 0},
            "maxLength" => {"type" => "integer", "minimum" => 0},
            "minItems" => {"type" => "integer", "minimum" => 0},
            "maxItems" => {"type" => "integer", "minimum" => 0},
            "minContains" => {"type" => "integer", "minimum" => 0},
            "maxContains" => {"type" => "integer", "minimum" => 0},
            "minProperties" => {"type" => "integer", "minimum" => 0},
            "maxProperties" => {"type" => "integer", "minimum" => 0}
          }
        }.freeze

        DIALECT = Dialect.new(
          name: :draft2019_09,
          uri: META_SCHEMA_URI,
          meta_schema: META_SCHEMA,
          keywords: KEYWORDS,
          ref_siblings: true
        )

        Dialect.register(DIALECT)

        private_constant :META_SCHEMA_URI, :META_SCHEMA, :KEYWORDS
      end
    end
  end

  private_constant :Internal
end
