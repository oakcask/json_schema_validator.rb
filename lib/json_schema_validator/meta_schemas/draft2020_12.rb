# frozen_string_literal: true

require_relative "../meta_schemas"

module JsonSchemaValidator
  module Internal
    module MetaSchemas
      module Draft202012
        META_SCHEMA_URI = "https://json-schema.org/draft/2020-12/schema"
        SCHEMA = {
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

        MetaSchemas.register(META_SCHEMA_URI, SCHEMA)

        private_constant :META_SCHEMA_URI, :SCHEMA
      end
    end
  end

  private_constant :Internal
end
