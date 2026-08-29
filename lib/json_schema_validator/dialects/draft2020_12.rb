# frozen_string_literal: true

require_relative "draft2019_09"

module JsonSchemaValidator
  module Internal
    module Dialects
      module Draft202012
        META_SCHEMA_URI = "https://json-schema.org/draft/2020-12/schema"

        KEYWORDS = Draft201909::DIALECT.keywords.merge(
          "$dynamicRef" => Dialect::Keyword.new(mask: Dialect::COMBINER),
          "prefixItems" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :list),
          "items" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single)
        ).except("additionalItems").freeze

        META_SCHEMA = {
          "$schema" => META_SCHEMA_URI,
          "$id" => META_SCHEMA_URI,
          "$dynamicAnchor" => "meta",
          "type" => ["object", "boolean"],
          "properties" => {
            "$defs" => {"type" => "object", "additionalProperties" => {"$dynamicRef" => "#meta"}},
            "definitions" => {"type" => "object", "additionalProperties" => {"$dynamicRef" => "#meta"}},
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
          name: :draft2020_12,
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
