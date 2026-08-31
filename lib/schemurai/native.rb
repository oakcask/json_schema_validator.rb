# frozen_string_literal: true

begin
  require "schemurai/schemurai_native"
rescue LoadError => installed_error
  begin
    require "schemurai_native"
  rescue LoadError
    raise installed_error
  end
end

unless Schemurai::Native::BACKEND == :native
  raise LoadError, "native extension reported an invalid backend identity"
end

module Schemurai
  module Native
    class Validator
      UNSUPPORTED_KEYWORDS = %w[
        $ref $recursiveRef $dynamicRef enum const allOf anyOf oneOf not if then else
        maximum minimum exclusiveMaximum exclusiveMinimum multipleOf maxLength minLength pattern
        contentEncoding contentMediaType maxItems minItems uniqueItems contains minContains maxContains
        maxProperties minProperties required properties patternProperties additionalProperties
        propertyNames dependencies dependentSchemas dependentRequired unevaluatedItems
        unevaluatedProperties items prefixItems additionalItems contentSchema format
      ].freeze

      def initialize(schema)
        if schema.is_a?(Hash) && (keyword = schema.keys.find { |key| UNSUPPORTED_KEYWORDS.include?(key) })
          raise Error, "native type slice does not support #{keyword.inspect}"
        end

        @graph = Graph.new(schema)
        Ractor.make_shareable(self)
      end

      def valid?(instance)
        @graph.valid?(instance)
      end

      def validate(instance)
        return Result.new([]) if valid?(instance)

        if @graph.schema == false
          return Result.new([
            ValidationError.new(
              keyword: "falseSchema",
              instance_path: "",
              schema_path: "",
              message: "boolean schema is false"
            )
          ])
        end

        types = Array(@graph.schema.fetch("type"))
        Result.new([
          ValidationError.new(
            keyword: "type",
            instance_path: "",
            schema_path: "/type",
            message: "expected #{types.join(" or ")}"
          )
        ])
      end

      def __validate_repeated__(instance, iterations)
        @graph.__validate_repeated__(instance, iterations)
      end

      private_constant :UNSUPPORTED_KEYWORDS
    end
  end
end
