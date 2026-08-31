# frozen_string_literal: true

module Schemurai
  module Internal
    # This module is both executable Ruby and the maintained translation root
    # for the first native validation slice.
    module TypeSlice
      module_function def valid?(type, value)
        return type.any? { |candidate| type?(value, candidate) } if type.is_a?(Array)

        type?(value, type)
      end

      module_function def type?(value, type)
        case type
        when "null" then value.nil?
        when "boolean" then value == true || value == false
        when "object" then value.is_a?(Hash)
        when "array" then value.is_a?(Array)
        when "number" then number?(value)
        when "integer" then number?(value) && value.finite? && value.to_i == value
        when "string" then value.is_a?(String)
        else false
        end
      end

      module_function def number?(value)
        value.is_a?(Numeric) && !value.is_a?(Complex)
      end
    end
  end
end
