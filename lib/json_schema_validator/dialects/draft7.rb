# frozen_string_literal: true

require_relative "../dialect"

module JsonSchemaValidator
  module Internal
    module Dialects
      module Draft7
        META_SCHEMA_URI = "http://json-schema.org/draft-07/schema"
        META_SCHEMA = {
          "$schema" => "#{META_SCHEMA_URI}#",
          "$id" => "#{META_SCHEMA_URI}#",
          "definitions" => {
            "schemaArray" => {"type" => "array", "minItems" => 1, "items" => {"$ref" => "#"}},
            "nonNegativeInteger" => {"type" => "integer", "minimum" => 0},
            "nonNegativeIntegerDefault0" => {
              "allOf" => [
                {"$ref" => "#/definitions/nonNegativeInteger"},
                {"default" => 0}
              ]
            },
            "simpleTypes" => {"enum" => %w[array boolean integer null number object string]},
            "stringArray" => {
              "type" => "array",
              "items" => {"type" => "string"},
              "uniqueItems" => true,
              "default" => []
            }
          },
          "type" => ["object", "boolean"],
          "properties" => {
            "$id" => {"type" => "string", "format" => "uri-reference"},
            "$schema" => {"type" => "string", "format" => "uri"},
            "$ref" => {"type" => "string", "format" => "uri-reference"},
            "$comment" => {"type" => "string"},
            "title" => {"type" => "string"},
            "description" => {"type" => "string"},
            "default" => true,
            "readOnly" => {"type" => "boolean", "default" => false},
            "writeOnly" => {"type" => "boolean", "default" => false},
            "examples" => {"type" => "array", "items" => true},
            "multipleOf" => {"type" => "number", "exclusiveMinimum" => 0},
            "maximum" => {"type" => "number"},
            "exclusiveMaximum" => {"type" => "number"},
            "minimum" => {"type" => "number"},
            "exclusiveMinimum" => {"type" => "number"},
            "maxLength" => {"$ref" => "#/definitions/nonNegativeInteger"},
            "minLength" => {"$ref" => "#/definitions/nonNegativeIntegerDefault0"},
            "pattern" => {"type" => "string", "format" => "regex"},
            "additionalItems" => {"$ref" => "#"},
            "items" => {
              "anyOf" => [{"$ref" => "#"}, {"$ref" => "#/definitions/schemaArray"}],
              "default" => true
            },
            "maxItems" => {"$ref" => "#/definitions/nonNegativeInteger"},
            "minItems" => {"$ref" => "#/definitions/nonNegativeIntegerDefault0"},
            "uniqueItems" => {"type" => "boolean", "default" => false},
            "contains" => {"$ref" => "#"},
            "maxProperties" => {"$ref" => "#/definitions/nonNegativeInteger"},
            "minProperties" => {"$ref" => "#/definitions/nonNegativeIntegerDefault0"},
            "required" => {"$ref" => "#/definitions/stringArray"},
            "additionalProperties" => {"$ref" => "#"},
            "definitions" => {
              "type" => "object",
              "additionalProperties" => {"$ref" => "#"},
              "default" => {}
            },
            "properties" => {
              "type" => "object",
              "additionalProperties" => {"$ref" => "#"},
              "default" => {}
            },
            "patternProperties" => {
              "type" => "object",
              "additionalProperties" => {"$ref" => "#"},
              "propertyNames" => {"format" => "regex"},
              "default" => {}
            },
            "dependencies" => {
              "type" => "object",
              "additionalProperties" => {
                "anyOf" => [{"$ref" => "#"}, {"$ref" => "#/definitions/stringArray"}]
              }
            },
            "propertyNames" => {"$ref" => "#"},
            "const" => true,
            "enum" => {"type" => "array", "items" => true, "minItems" => 1, "uniqueItems" => true},
            "type" => {
              "anyOf" => [
                {"$ref" => "#/definitions/simpleTypes"},
                {
                  "type" => "array",
                  "items" => {"$ref" => "#/definitions/simpleTypes"},
                  "minItems" => 1,
                  "uniqueItems" => true
                }
              ]
            },
            "format" => {"type" => "string"},
            "contentMediaType" => {"type" => "string"},
            "contentEncoding" => {"type" => "string"},
            "if" => {"$ref" => "#"},
            "then" => {"$ref" => "#"},
            "else" => {"$ref" => "#"},
            "allOf" => {"$ref" => "#/definitions/schemaArray"},
            "anyOf" => {"$ref" => "#/definitions/schemaArray"},
            "oneOf" => {"$ref" => "#/definitions/schemaArray"},
            "not" => {"$ref" => "#"}
          },
          "default" => true
        }.freeze

        KEYWORDS = {
          "type" => Dialect::Keyword.new(mask: Dialect::TYPE),
          "enum" => Dialect::Keyword.new(mask: Dialect::ENUM),
          "const" => Dialect::Keyword.new(mask: Dialect::ENUM),
          "allOf" => Dialect::Keyword.new(mask: Dialect::COMBINER, subschema_shape: :list),
          "anyOf" => Dialect::Keyword.new(mask: Dialect::COMBINER, subschema_shape: :list),
          "oneOf" => Dialect::Keyword.new(mask: Dialect::COMBINER, subschema_shape: :list),
          "not" => Dialect::Keyword.new(mask: Dialect::COMBINER, subschema_shape: :single),
          "if" => Dialect::Keyword.new(mask: Dialect::COMBINER, subschema_shape: :single),
          "then" => Dialect::Keyword.new(mask: 0, subschema_shape: :single),
          "else" => Dialect::Keyword.new(mask: 0, subschema_shape: :single),
          "maximum" => Dialect::Keyword.new(mask: Dialect::NUMBER),
          "minimum" => Dialect::Keyword.new(mask: Dialect::NUMBER),
          "exclusiveMaximum" => Dialect::Keyword.new(mask: Dialect::NUMBER),
          "exclusiveMinimum" => Dialect::Keyword.new(mask: Dialect::NUMBER),
          "multipleOf" => Dialect::Keyword.new(mask: Dialect::NUMBER),
          "maxLength" => Dialect::Keyword.new(mask: Dialect::STRING),
          "minLength" => Dialect::Keyword.new(mask: Dialect::STRING),
          "pattern" => Dialect::Keyword.new(mask: Dialect::STRING),
          "contentEncoding" => Dialect::Keyword.new(mask: Dialect::STRING),
          "contentMediaType" => Dialect::Keyword.new(mask: Dialect::STRING),
          "maxItems" => Dialect::Keyword.new(mask: Dialect::ARRAY),
          "minItems" => Dialect::Keyword.new(mask: Dialect::ARRAY),
          "uniqueItems" => Dialect::Keyword.new(mask: Dialect::ARRAY),
          "items" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single_or_list),
          "additionalItems" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single),
          "contains" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single),
          "maxProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT),
          "minProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT),
          "required" => Dialect::Keyword.new(mask: Dialect::OBJECT),
          "properties" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :map),
          "patternProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :map),
          "additionalProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :single),
          "propertyNames" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :single),
          "dependencies" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :dependencies),
          "definitions" => Dialect::Keyword.new(mask: 0, subschema_shape: :map)
        }.freeze

        DIALECT = Dialect.new(
          name: :draft7,
          uri: META_SCHEMA_URI,
          meta_schema: META_SCHEMA,
          keywords: KEYWORDS,
          ref_siblings: false
        )

        Dialect.register(DIALECT, default: true)

        private_constant :META_SCHEMA_URI, :META_SCHEMA, :KEYWORDS
      end
    end
  end

  private_constant :Internal
end
