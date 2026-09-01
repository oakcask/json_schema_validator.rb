# frozen_string_literal: true

module Schemurai
  module Internal
    # Builds validation messages shared by every evaluator backend.
    module ErrorMessage
      module_function def false_schema = "value is not allowed by this schema"

      module_function def type(expected, value)
        expected = Array(expected).map { |name| name.inspect }.join(" or ")
        "value has type #{json_type(value).inspect}, but must have type #{expected}"
      end

      module_function def enum = "value must equal one of the values defined by `enum`"
      module_function def const = "value must equal the value defined by `const`"

      module_function def numeric_limit(keyword, limit)
        comparison = {
          "maximum" => "less than or equal to",
          "minimum" => "greater than or equal to",
          "exclusiveMaximum" => "less than",
          "exclusiveMinimum" => "greater than"
        }.fetch(keyword)
        "number must be #{comparison} #{display_number(limit)}"
      end

      module_function def multiple_of(divisor) = "number must be a multiple of #{display_number(divisor)}"

      module_function def size(keyword, limit, actual)
        subject, unit, comparison = {
          "maxLength" => ["string", "characters", "at most"],
          "minLength" => ["string", "characters", "at least"],
          "maxItems" => ["array", "items", "at most"],
          "minItems" => ["array", "items", "at least"],
          "maxProperties" => ["object", "properties", "at most"],
          "minProperties" => ["object", "properties", "at least"]
        }.fetch(keyword)
        unit = {"characters" => "character", "items" => "item", "properties" => "property"}.fetch(unit) if limit == 1
        "#{subject} must contain #{comparison} #{limit} #{unit} (found #{actual})"
      end

      module_function def pattern(pattern) = "string must match pattern #{pattern.inspect}"
      module_function def invalid_pattern(pattern) = "schema pattern #{pattern.inspect} is not a valid regular expression"
      module_function def format(name) = "string must match the #{name} format"
      module_function def content_encoding = "string must be valid base64"
      module_function def content_media_type = "string must contain valid JSON"
      module_function def unique_items = "array items must be unique"

      module_function def contains(actual, minimum, maximum)
        expected = if maximum.infinite?
          "at least #{minimum}"
        elsif minimum == maximum
          "exactly #{minimum}"
        elsif minimum.zero?
          "at most #{maximum}"
        else
          "between #{minimum} and #{maximum}"
        end
        "array must contain #{expected} items matching `contains` (found #{actual})"
      end

      module_function def required(name) = "object is missing required property #{name.inspect}"

      module_function def dependent_required(name, required_name)
        "property #{required_name.inspect} is required when property #{name.inspect} is present"
      end

      module_function def any_of = "value must match at least one subschema"
      module_function def one_of(matches) = "value must match exactly one subschema (matched #{matches})"
      module_function def not = "value must not match the subschema"

      module_function def json_type(value)
        case value
        when nil then "null"
        when true, false then "boolean"
        when Hash then "object"
        when Array then "array"
        when String then "string"
        when Numeric
          if value.is_a?(Complex)
            value.class.name
          elsif value.finite? && value.to_i == value
            "integer"
          else
            "number"
          end
        else
          value.class.name
        end
      end
      private_class_method :json_type

      module_function def display_number(value)
        rational = value.is_a?(Rational) ? value : Rational(value.to_s)
        return rational.numerator.to_s if rational.denominator == 1

        rational.to_f.to_s
      end
      private_class_method :display_number
    end
  end
end
