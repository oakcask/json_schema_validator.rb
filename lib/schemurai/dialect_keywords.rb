# frozen_string_literal: true

require_relative "dialect"

module Schemurai
  module Internal
    module DialectKeywords
      COMMON = {
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
        "contains" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single),
        "maxProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT),
        "minProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT),
        "required" => Dialect::Keyword.new(mask: Dialect::OBJECT),
        "properties" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :map),
        "patternProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :map),
        "additionalProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :single),
        "propertyNames" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :single)
      }.freeze

      LEGACY = {
        "dependencies" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :dependencies),
        "definitions" => Dialect::Keyword.new(mask: 0, subschema_shape: :map)
      }.freeze

      MODERN = {
        "$defs" => Dialect::Keyword.new(mask: 0, subschema_shape: :map),
        "$recursiveRef" => Dialect::Keyword.new(mask: Dialect::COMBINER),
        "dependentSchemas" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :map),
        "dependentRequired" => Dialect::Keyword.new(mask: Dialect::OBJECT),
        "minContains" => Dialect::Keyword.new(mask: Dialect::ARRAY),
        "maxContains" => Dialect::Keyword.new(mask: Dialect::ARRAY),
        "unevaluatedItems" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single),
        "unevaluatedProperties" => Dialect::Keyword.new(mask: Dialect::OBJECT, subschema_shape: :single),
        "contentSchema" => Dialect::Keyword.new(mask: Dialect::STRING, subschema_shape: :single)
      }.freeze

      private_constant :COMMON, :LEGACY, :MODERN

      module_function def draft7
        COMMON.merge(
          LEGACY,
          "items" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single_or_list),
          "additionalItems" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single)
        ).freeze
      end

      module_function def draft2019_09
        COMMON.merge(
          LEGACY,
          MODERN,
          "items" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single_or_list),
          "additionalItems" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single)
        ).freeze
      end

      module_function def draft2020_12
        COMMON.merge(
          LEGACY,
          MODERN,
          "$dynamicRef" => Dialect::Keyword.new(mask: Dialect::COMBINER),
          "prefixItems" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :list),
          "items" => Dialect::Keyword.new(mask: Dialect::ARRAY, subschema_shape: :single)
        ).freeze
      end
    end
  end

  private_constant :Internal
end
