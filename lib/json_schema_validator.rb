# frozen_string_literal: true

require "json"
require "base64"
require_relative "json_schema_validator/evaluation"
require_relative "json_schema_validator/schema_graph"

module JsonSchemaValidator
  class ResolutionError < StandardError; end

  Error = Data.define(:keyword, :instance_path, :schema_path, :message) do
    def to_h
      {keyword: keyword, instance_path: instance_path, schema_path: schema_path, message: message}
    end
  end

  class Result
    attr_reader :errors

    def initialize(errors)
      @errors = errors.freeze
    end

    def valid?
      errors.empty?
    end

    alias_method :success?, :valid?
  end

  module Internal
    class Evaluator
      def initialize(schema, schemas: {}, base_uri: nil, content: false)
        @validate_content = content
        @graph = SchemaGraph.new(schema, schemas: schemas, base_uri: base_uri)
        @root = @graph.root
        @regexps = nil
        @active = nil
      end

      def validate(instance)
        @errors = []
        @error_count = 0
        evaluate(@root, instance, "", "")
        Result.new(@errors)
      end

      def valid?(instance)
        @errors = nil
        @error_count = 0
        evaluate(@root, instance, nil, nil).valid?
      end

      private def evaluate(node, instance, instance_path, schema_path)
        schema = node.schema
        return Evaluation.valid if schema == true
        if schema == false
          add_error("falseSchema", instance_path, schema_path, "boolean schema is false")
          return Evaluation.invalid
        end
        return Evaluation.valid unless schema.is_a?(Hash)

        before = @error_count

        if schema.key?("$ref")
          instances = active_instances(node)
          instance_id = instance.object_id
          if instances[instance_id]
            return Evaluation.valid unless node.dialect.ref_siblings?
          else
            instances[instance_id] = true
            begin
              target = @graph.resolve(node, schema["$ref"])
              evaluate(target, instance, instance_path, append(schema_path, "$ref"))
            rescue ResolutionError => e
              add_error("$ref", instance_path, schema_path, e.message)
            ensure
              instances.delete(instance_id)
            end
          end
          return (@error_count == before) ? Evaluation.valid : Evaluation.invalid unless node.dialect.ref_siblings?
        end

        keywords = node.keyword_mask
        categories = Internal::Dialect
        check_type(schema, instance, instance_path, schema_path) if (keywords & categories::TYPE) != 0
        check_enum(schema, instance, instance_path, schema_path) if (keywords & categories::ENUM) != 0
        check_combiners(node, instance, instance_path, schema_path) if (keywords & categories::COMBINER) != 0

        case instance
        when Hash
          check_object(node, instance, instance_path, schema_path) if (keywords & categories::OBJECT) != 0
        when Array
          check_array(node, instance, instance_path, schema_path) if (keywords & categories::ARRAY) != 0
        when String
          check_string(schema, instance, instance_path, schema_path) if (keywords & categories::STRING) != 0
        when Numeric
          check_number(schema, instance, instance_path, schema_path) if !instance.is_a?(Complex) && (keywords & categories::NUMBER) != 0
        end

        (@error_count == before) ? Evaluation.valid : Evaluation.invalid
      end

      private def active_instances(node)
        active = (@active ||= {})
        active[node.object_id] ||= {}
      end

      private def check_type(schema, value, path, schema_path)
        return unless schema.key?("type")

        types = Array(schema["type"])
        return if types.any? { |type| type?(value, type) }

        add_error("type", path, append(schema_path, "type"), "expected #{types.join(" or ")}")
      end

      private def check_enum(schema, value, path, schema_path)
        if schema.key?("enum") && !schema["enum"].any? { |candidate| json_equal?(candidate, value) }
          add_error("enum", path, append(schema_path, "enum"), "value is not in enum")
        end
        if schema.key?("const") && !json_equal?(schema["const"], value)
          add_error("const", path, append(schema_path, "const"), "value does not equal const")
        end
      end

      private def check_combiners(node, value, path, schema_path)
        schema = node.schema
        if schema.key?("allOf")
          schema["allOf"].each_index do |index|
            evaluate(node.child(["allOf", index]), value, path, append(append(schema_path, "allOf"), index))
          end
        end

        if schema.key?("anyOf")
          matches = schema["anyOf"].each_index.count do |index|
            trial(node.child(["anyOf", index]), value, path, append(append(schema_path, "anyOf"), index)).valid?
          end
          add_error("anyOf", path, append(schema_path, "anyOf"), "no subschema matched") if matches.zero?
        end

        if schema.key?("oneOf")
          matches = schema["oneOf"].each_index.count do |index|
            trial(node.child(["oneOf", index]), value, path, append(append(schema_path, "oneOf"), index)).valid?
          end
          add_error("oneOf", path, append(schema_path, "oneOf"), "expected exactly one match, got #{matches}") unless matches == 1
        end

        if schema.key?("not") && trial(node.child("not"), value, path, append(schema_path, "not")).valid?
          add_error("not", path, append(schema_path, "not"), "subschema matched")
        end

        return unless schema.key?("if")

        condition = trial(node.child("if"), value, path, append(schema_path, "if")).valid?
        branch = condition ? "then" : "else"
        evaluate(node.child(branch), value, path, append(schema_path, branch)) if schema.key?(branch)
      end

      private def check_number(schema, value, path, schema_path)
        compare(schema, "maximum", value, path, schema_path) { |a, b| a <= b }
        compare(schema, "minimum", value, path, schema_path) { |a, b| a >= b }
        compare(schema, "exclusiveMaximum", value, path, schema_path) { |a, b| a < b }
        compare(schema, "exclusiveMinimum", value, path, schema_path) { |a, b| a > b }

        return unless schema.key?("multipleOf")

        divisor = decimal(schema["multipleOf"])
        valid = divisor.positive? && decimal(value).remainder(divisor).zero?
        add_error("multipleOf", path, append(schema_path, "multipleOf"), "number is not a multiple") unless valid
      end

      private def compare(schema, keyword, value, path, schema_path)
        return unless schema.key?(keyword)
        return if yield(decimal(value), decimal(schema[keyword]))

        add_error(keyword, path, append(schema_path, keyword), "numeric limit was exceeded")
      end

      private def check_string(schema, value, path, schema_path)
        length = value.length
        limit(schema, "maxLength", length, path, schema_path) { |actual, expected| actual <= expected }
        limit(schema, "minLength", length, path, schema_path) { |actual, expected| actual >= expected }

        if schema.key?("pattern")
          matched = ecma_regexp(schema["pattern"]).match?(value)
          add_error("pattern", path, append(schema_path, "pattern"), "string does not match pattern") unless matched
        end
        check_content(schema, value, path, schema_path) if @validate_content
      rescue RegexpError
        add_error("pattern", path, append(schema_path, "pattern"), "invalid regular expression")
      end

      private def check_array(node, value, path, schema_path)
        schema = node.schema
        limit(schema, "maxItems", value.length, path, schema_path) { |actual, expected| actual <= expected }
        limit(schema, "minItems", value.length, path, schema_path) { |actual, expected| actual >= expected }

        if schema["uniqueItems"]
          duplicate = value.each_with_index.any? do |item, index|
            value[0...index].any? { |previous| json_equal?(previous, item) }
          end
          add_error("uniqueItems", path, append(schema_path, "uniqueItems"), "array items are not unique") if duplicate
        end

        items = schema["items"]
        if items.is_a?(Array)
          items.each_index do |index|
            break if index >= value.length
            evaluate(node.child(["items", index]), value[index], append(path, index), append(append(schema_path, "items"), index))
          end
          if value.length > items.length && schema.key?("additionalItems")
            additional = node.child("additionalItems")
            (items.length...value.length).each do |index|
              evaluate(additional, value[index], append(path, index), append(schema_path, "additionalItems"))
            end
          end
        elsif !items.nil?
          value.each_with_index do |item, index|
            evaluate(node.child("items"), item, append(path, index), append(schema_path, "items"))
          end
        end

        return unless schema.key?("contains")

        matched = value.each_with_index.any? do |item, index|
          trial(node.child("contains"), item, append(path, index), append(schema_path, "contains")).valid?
        end
        add_error("contains", path, append(schema_path, "contains"), "no array item matched") unless matched
      end

      private def check_object(node, value, path, schema_path)
        schema = node.schema
        limit(schema, "maxProperties", value.length, path, schema_path) { |actual, expected| actual <= expected }
        limit(schema, "minProperties", value.length, path, schema_path) { |actual, expected| actual >= expected }

        Array(schema["required"]).each do |name|
          add_error("required", path, append(schema_path, "required"), "required property #{name.inspect} is missing") unless value.key?(name)
        end

        properties = schema.fetch("properties", {})
        patterns = schema.fetch("patternProperties", {})
        value.each do |name, property_value|
          matched = false
          if properties.key?(name)
            matched = true
            evaluate(node.child(["properties", name]), property_value, append(path, name), append(append(schema_path, "properties"), name))
          end
          patterns.each do |pattern, subschema|
            next unless ecma_regexp(pattern).match?(name)
            matched = true
            evaluate(node.child(["patternProperties", pattern]), property_value, append(path, name), append(append(schema_path, "patternProperties"), pattern))
          end
          if !matched && schema.key?("additionalProperties")
            evaluate(node.child("additionalProperties"), property_value, append(path, name), append(schema_path, "additionalProperties"))
          end
        end

        if schema.key?("propertyNames")
          value.each_key do |name|
            evaluate(node.child("propertyNames"), name, append(path, name), append(schema_path, "propertyNames"))
          end
        end

        schema.fetch("dependencies", {}).each do |name, dependency|
          next unless value.key?(name)
          if dependency.is_a?(Array)
            dependency.each do |required_name|
              add_error("dependencies", path, append(schema_path, "dependencies"), "property #{required_name.inspect} is required by #{name.inspect}") unless value.key?(required_name)
            end
          else
            evaluate(node.child(["dependencies", name]), value, path, append(append(schema_path, "dependencies"), name))
          end
        end
      end

      private def trial(node, value, path, schema_path)
        saved_errors = @errors
        saved_error_count = @error_count
        @errors = [] if saved_errors
        @error_count = 0
        result = evaluate(node, value, path, schema_path)
        result
      ensure
        @errors = saved_errors
        @error_count = saved_error_count
      end

      private def limit(schema, keyword, actual, path, schema_path)
        return unless schema.key?(keyword)
        return if yield(actual, schema[keyword])

        add_error(keyword, path, append(schema_path, keyword), "size limit was exceeded")
      end

      private def type?(value, type)
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

      private def number?(value)
        value.is_a?(Numeric) && !value.is_a?(Complex)
      end

      private def json_equal?(left, right)
        return false if json_kind(left) != json_kind(right)
        case left
        when Hash
          left.length == right.length && left.all? { |key, value| right.key?(key) && json_equal?(value, right[key]) }
        when Array
          left.length == right.length && left.each_index.all? { |index| json_equal?(left[index], right[index]) }
        else
          left == right
        end
      end

      private def json_kind(value)
        return :number if number?(value)
        return :boolean if value == true || value == false
        value.class
      end

      private def decimal(value)
        return value if value.is_a?(Integer) || value.is_a?(Rational)

        Rational(value.to_s)
      end

      # Ruby and ECMA-262 differ in their ASCII character classes, anchors, and
      # definition of whitespace. Draft 7 patterns use the ECMA behavior.
      private def ecma_regexp(pattern)
        regexps = (@regexps ||= {})
        return regexps[pattern] if regexps.key?(pattern)

        whitespace = "\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF"
        translated = +""
        escaped = false
        in_class = false
        pattern.each_char do |character|
          if escaped
            translated << case character
            when "d" then in_class ? "0-9" : "[0-9]"
            when "D" then in_class ? "^0-9" : "[^0-9]"
            when "w" then in_class ? "A-Za-z0-9_" : "[A-Za-z0-9_]"
            when "W" then in_class ? "^A-Za-z0-9_" : "[^A-Za-z0-9_]"
            when "s" then in_class ? whitespace : "[#{whitespace}]"
            when "S" then in_class ? "^#{whitespace}" : "[^#{whitespace}]"
            else "\\#{character}"
            end
            escaped = false
          elsif character == "\\"
            escaped = true
          elsif character == "["
            in_class = true
            translated << character
          elsif character == "]"
            in_class = false
            translated << character
          elsif character == "^" && !in_class
            translated << "\\A"
          elsif character == "$" && !in_class
            translated << "\\z"
          else
            translated << character
          end
        end
        translated << "\\" if escaped
        regexps[pattern] = Regexp.new(translated)
      end

      private def check_content(schema, value, path, schema_path)
        decoded = value
        if schema["contentEncoding"] == "base64"
          decoded = Base64.strict_decode64(value)
        end
        return unless schema["contentMediaType"] == "application/json"

        JSON.parse(decoded)
      rescue ArgumentError, JSON::ParserError
        keyword = (schema["contentEncoding"] == "base64") ? "contentEncoding" : "contentMediaType"
        add_error(keyword, path, append(schema_path, keyword), "string content is invalid")
      end

      private def add_error(keyword, instance_path, schema_path, message)
        @error_count += 1
        @errors << Error.new(keyword: keyword, instance_path: instance_path, schema_path: schema_path, message: message) if @errors
        false
      end

      private def append(path, segment)
        return if path.nil?

        "#{path}/#{segment.to_s.gsub("~", "~0").gsub("/", "~1")}"
      end
    end
  end

  class Validator
    def initialize(schema, schemas: {}, base_uri: nil, content: false)
      @evaluator = Internal::Evaluator.new(
        schema,
        schemas: schemas,
        base_uri: base_uri,
        content: content
      )
    end

    def validate(instance)
      @evaluator.validate(instance)
    end

    def valid?(instance)
      @evaluator.valid?(instance)
    end
  end

  module_function def validate(schema, instance, **options)
    Validator.new(schema, **options).validate(instance)
  end

  module_function def valid?(schema, instance, **options)
    Validator.new(schema, **options).valid?(instance)
  end
end
