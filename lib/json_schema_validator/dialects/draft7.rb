# frozen_string_literal: true

require "json"
require_relative "../dialect"

module JsonSchemaValidator
  module Internal
    module Dialects
      module Draft7
        META_SCHEMA_URI = "http://json-schema.org/draft-07/schema"
        META_SCHEMA = JSON.parse(
          File.read(File.join(__dir__, "..", "draft7_schema.json"))
        ).freeze

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
