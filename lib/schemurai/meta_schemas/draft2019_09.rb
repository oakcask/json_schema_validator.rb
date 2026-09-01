# frozen_string_literal: true

require_relative "../meta_schemas"

module Schemurai
  module Internal
    module MetaSchemas
      module Draft201909
        META_SCHEMA_URI = "https://json-schema.org/draft/2019-09/schema"
        SCHEMA = {
          "$schema" => META_SCHEMA_URI,
          "$id" => META_SCHEMA_URI,
          "$recursiveAnchor" => true,
          "type" => ["object", "boolean"],
          "properties" => {
            "$id" => {"type" => "string"},
            "$schema" => {"type" => "string"},
            "$ref" => {"type" => "string"},
            "$anchor" => {"type" => "string", "pattern" => "^[A-Za-z][-A-Za-z0-9.:_]*$"},
            "$recursiveRef" => {"type" => "string"},
            "$recursiveAnchor" => {"type" => "boolean"},
            "$vocabulary" => {"type" => "object", "additionalProperties" => {"type" => "boolean"}},
            "$comment" => {"type" => "string"},
            "$defs" => {"type" => "object", "additionalProperties" => {"$recursiveRef" => "#"}},
            "definitions" => {"type" => "object", "additionalProperties" => {"$recursiveRef" => "#"}},
            "items" => {
              "anyOf" => [
                {"$recursiveRef" => "#"},
                {"type" => "array", "minItems" => 1, "items" => {"$recursiveRef" => "#"}}
              ]
            },
            "additionalItems" => {"$recursiveRef" => "#"},
            "contains" => {"$recursiveRef" => "#"},
            "additionalProperties" => {"$recursiveRef" => "#"},
            "unevaluatedItems" => {"$recursiveRef" => "#"},
            "unevaluatedProperties" => {"$recursiveRef" => "#"},
            "properties" => {"type" => "object", "additionalProperties" => {"$recursiveRef" => "#"}},
            "patternProperties" => {"type" => "object", "additionalProperties" => {"$recursiveRef" => "#"}},
            "dependentSchemas" => {"type" => "object", "additionalProperties" => {"$recursiveRef" => "#"}},
            "dependencies" => {
              "type" => "object",
              "additionalProperties" => {
                "anyOf" => [
                  {"$recursiveRef" => "#"},
                  {"type" => "array", "items" => {"type" => "string"}, "uniqueItems" => true}
                ]
              }
            },
            "propertyNames" => {"$recursiveRef" => "#"},
            "if" => {"$recursiveRef" => "#"},
            "then" => {"$recursiveRef" => "#"},
            "else" => {"$recursiveRef" => "#"},
            "allOf" => {"type" => "array", "minItems" => 1, "items" => {"$recursiveRef" => "#"}},
            "anyOf" => {"type" => "array", "minItems" => 1, "items" => {"$recursiveRef" => "#"}},
            "oneOf" => {"type" => "array", "minItems" => 1, "items" => {"$recursiveRef" => "#"}},
            "not" => {"$recursiveRef" => "#"},
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
            "enum" => {"type" => "array"},
            "multipleOf" => {"type" => "number", "exclusiveMinimum" => 0},
            "maximum" => {"type" => "number"},
            "exclusiveMaximum" => {"type" => "number"},
            "minimum" => {"type" => "number"},
            "exclusiveMinimum" => {"type" => "number"},
            "minLength" => {"type" => "integer", "minimum" => 0},
            "maxLength" => {"type" => "integer", "minimum" => 0},
            "pattern" => {"type" => "string"},
            "minItems" => {"type" => "integer", "minimum" => 0},
            "maxItems" => {"type" => "integer", "minimum" => 0},
            "uniqueItems" => {"type" => "boolean"},
            "minContains" => {"type" => "integer", "minimum" => 0},
            "maxContains" => {"type" => "integer", "minimum" => 0},
            "minProperties" => {"type" => "integer", "minimum" => 0},
            "maxProperties" => {"type" => "integer", "minimum" => 0},
            "required" => {
              "type" => "array",
              "items" => {"type" => "string"},
              "uniqueItems" => true
            },
            "dependentRequired" => {
              "type" => "object",
              "additionalProperties" => {
                "type" => "array",
                "items" => {"type" => "string"},
                "uniqueItems" => true
              }
            },
            "title" => {"type" => "string"},
            "description" => {"type" => "string"},
            "deprecated" => {"type" => "boolean"},
            "readOnly" => {"type" => "boolean"},
            "writeOnly" => {"type" => "boolean"},
            "examples" => {"type" => "array"},
            "format" => {"type" => "string"},
            "contentEncoding" => {"type" => "string"},
            "contentMediaType" => {"type" => "string"},
            "contentSchema" => {"$recursiveRef" => "#"}
          }
        }.freeze

        MetaSchemas.register(META_SCHEMA_URI, SCHEMA)

        COMPONENT_KEYWORDS = {
          "core" => %w[
            $id $schema $ref $anchor $recursiveRef $recursiveAnchor $vocabulary $comment $defs
          ],
          "applicator" => %w[
            additionalItems unevaluatedItems items contains additionalProperties
            unevaluatedProperties properties patternProperties dependentSchemas propertyNames
            if then else allOf anyOf oneOf not
          ],
          "validation" => %w[
            type const enum multipleOf maximum exclusiveMaximum minimum exclusiveMinimum
            maxLength minLength pattern maxItems minItems uniqueItems maxContains minContains
            maxProperties minProperties required dependentRequired
          ],
          "meta-data" => %w[title description default deprecated readOnly writeOnly examples],
          "format" => %w[format],
          "content" => %w[contentEncoding contentMediaType contentSchema]
        }.freeze

        COMPONENT_KEYWORDS.each do |name, keywords|
          uri = "https://json-schema.org/draft/2019-09/meta/#{name}"
          component = {
            "$schema" => META_SCHEMA_URI,
            "$id" => uri,
            "$recursiveAnchor" => true,
            "type" => ["object", "boolean"],
            "properties" => SCHEMA.fetch("properties").slice(*keywords)
          }.freeze
          MetaSchemas.register(uri, component)
        end

        private_constant :META_SCHEMA_URI, :SCHEMA, :COMPONENT_KEYWORDS
      end
    end
  end

  private_constant :Internal
end
