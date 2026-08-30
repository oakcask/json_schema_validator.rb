# frozen_string_literal: true

require "json"
require "base64"
require_relative "json_schema_validator/evaluation"
require_relative "json_schema_validator/formats"
require_relative "json_schema_validator/schema_graph"

module JsonSchemaValidator
  class Error < StandardError; end
  class ResolutionError < Error; end
  class UnsupportedFormatError < Error; end

  ValidationError = Data.define(:keyword, :instance_path, :schema_path, :message) do
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

  class CompiledSchema
    def initialize(graph, root)
      @graph = graph
      @root = root
      freeze
    end

    attr_reader :graph, :root
    private :graph, :root
    private_class_method :new
  end

  class SchemaRegistry
    UNDEFINED_SCHEMA = Object.new.freeze
    private_constant :UNDEFINED_SCHEMA

    def initialize(schemas: {})
      @graph = Internal::SchemaGraph.new(schemas: schemas)
    end

    def compile(schema = UNDEFINED_SCHEMA, base_uri: nil, **schema_keywords)
      if schema.equal?(UNDEFINED_SCHEMA)
        raise ArgumentError, "schema is required" if schema_keywords.empty?

        schema = schema_keywords
      elsif !schema_keywords.empty?
        raise ArgumentError, "schema must be passed as one object"
      end

      root = @graph.compile(schema, base_uri: base_uri)
      CompiledSchema.send(:new, @graph, root)
    end
  end

  module Internal
    class Evaluator
      def initialize(schema, content: false, format: false)
        @validate_content = content
        @validate_format = format
        @graph = schema.send(:graph)
        @root = schema.send(:root)
        @regexps = nil
        @active = nil
      end

      def validate(instance)
        @errors = []
        @error_count = 0
        @track_dynamic_scope = @graph.dynamic_scope?
        evaluate(@root, instance, "", "")
        Result.new(@errors)
      end

      def valid?(instance)
        @errors = nil
        @error_count = 0
        @track_dynamic_scope = @graph.dynamic_scope?
        evaluate_valid(@root, instance)
      end

      private def evaluate_valid(node, instance)
        schema = node.schema
        return schema if schema == true || schema == false
        return true unless schema.is_a?(Hash)

        # These applicators depend on annotations collected from sibling
        # applicators. Keep them on the full evaluation path; schemas without
        # them can avoid allocating Evaluation objects and JSON Pointer paths.
        if schema.key?("unevaluatedProperties") || schema.key?("unevaluatedItems")
          return evaluate(node, instance, nil, nil).valid?
        end

        if @track_dynamic_scope
          entered_scope = @dynamic_scope.nil? || !@dynamic_scope.last.equal?(node.resource)
          (@dynamic_scope ||= []) << node.resource if entered_scope
        end

        if schema.key?("$ref")
          return false unless valid_reference?(node, @graph.resolve(node, schema["$ref"]), instance)
          return true unless node.dialect.ref_siblings?
        end

        if schema.key?("$recursiveRef")
          return false unless valid_reference?(node, recursive_target(node, schema["$recursiveRef"]), instance)
        end

        if schema.key?("$dynamicRef")
          return false unless valid_reference?(node, dynamic_target(node, schema["$dynamicRef"]), instance)
        end

        keywords = node.keyword_mask
        if keywords.zero? && format_asserted?(node)
          return !instance.is_a?(String) || node.format.call(instance)
        end

        categories = Internal::Dialect
        return false if (keywords & categories::TYPE) != 0 && !valid_type?(schema, instance)
        return false if (keywords & categories::ENUM) != 0 && !valid_enum?(schema, instance)
        return false if (keywords & categories::COMBINER) != 0 && !valid_combiners?(node, instance)

        case instance
        when Hash
          (keywords & categories::OBJECT) == 0 || valid_object?(node, instance)
        when Array
          (keywords & categories::ARRAY) == 0 || valid_array?(node, instance)
        when String
          if (keywords & categories::STRING) != 0
            valid_string?(node, instance)
          elsif format_asserted?(node)
            node.format.call(instance)
          else
            true
          end
        when Numeric
          instance.is_a?(Complex) || (keywords & categories::NUMBER) == 0 || valid_number?(schema, instance)
        else
          true
        end
      rescue ResolutionError
        false
      ensure
        @dynamic_scope.pop if entered_scope
      end

      private def valid_reference?(source, target, instance)
        instances = active_instances(source)
        instance_id = instance.object_id
        return true if instances[instance_id]

        instances[instance_id] = true
        activated = true
        evaluate_valid(target, instance)
      ensure
        instances&.delete(instance_id) if activated
      end

      private def valid_type?(schema, value)
        types = schema["type"]
        return types.any? { |type| type?(value, type) } if types.is_a?(Array)

        type?(value, types)
      end

      private def valid_enum?(schema, value)
        return false if schema.key?("enum") && !schema["enum"].any? { |candidate| json_equal?(candidate, value) }
        return false if schema.key?("const") && !json_equal?(schema["const"], value)

        true
      end

      private def valid_combiners?(node, value)
        schema = node.schema
        if schema.key?("allOf")
          schema["allOf"].each_index do |index|
            return false unless evaluate_valid(node.child("allOf", index), value)
          end
        end
        if schema.key?("anyOf")
          matched = schema["anyOf"].each_index.any? do |index|
            evaluate_valid(node.child("anyOf", index), value)
          end
          return false unless matched
        end
        if schema.key?("oneOf")
          matches = 0
          schema["oneOf"].each_index do |index|
            matches += 1 if evaluate_valid(node.child("oneOf", index), value)
            return false if matches > 1
          end
          return false unless matches == 1
        end
        return false if schema.key?("not") && evaluate_valid(node.child("not"), value)

        if schema.key?("if")
          branch = evaluate_valid(node.child("if"), value) ? "then" : "else"
          return false if schema.key?(branch) && !evaluate_valid(node.child(branch), value)
        end
        true
      end

      private def valid_number?(schema, value)
        actual = nil
        if schema.key?("maximum")
          actual ||= decimal(value)
          return false unless actual <= decimal(schema["maximum"])
        end
        if schema.key?("minimum")
          actual ||= decimal(value)
          return false unless actual >= decimal(schema["minimum"])
        end
        if schema.key?("exclusiveMaximum")
          actual ||= decimal(value)
          return false unless actual < decimal(schema["exclusiveMaximum"])
        end
        if schema.key?("exclusiveMinimum")
          actual ||= decimal(value)
          return false unless actual > decimal(schema["exclusiveMinimum"])
        end
        if schema.key?("multipleOf")
          divisor = decimal(schema["multipleOf"])
          return false unless divisor.positive?
          return false unless (actual || decimal(value)).remainder(divisor).zero?
        end
        true
      end

      private def valid_string?(node, value)
        schema = node.schema
        length = value.length
        return false if schema.key?("maxLength") && length > schema["maxLength"]
        return false if schema.key?("minLength") && length < schema["minLength"]
        return false if schema.key?("pattern") && !ecma_regexp(schema["pattern"]).match?(value)
        if format_asserted?(node)
          return false unless node.format.call(value)
        end
        return valid_content?(schema, value) if @validate_content

        true
      rescue RegexpError, IPAddr::InvalidAddressError
        false
      end

      private def valid_content?(schema, value)
        decoded = (schema["contentEncoding"] == "base64") ? Base64.strict_decode64(value) : value
        JSON.parse(decoded) if schema["contentMediaType"] == "application/json"
        true
      rescue ArgumentError, JSON::ParserError
        false
      end

      private def valid_array?(node, value)
        schema = node.schema
        length = value.length
        return false if schema.key?("maxItems") && length > schema["maxItems"]
        return false if schema.key?("minItems") && length < schema["minItems"]
        if schema["uniqueItems"]
          value.each_with_index do |item, index|
            return false if value[0...index].any? { |previous| json_equal?(previous, item) }
          end
        end

        prefix_items = schema["prefixItems"]
        if prefix_items.is_a?(Array)
          prefix_items.each_index do |index|
            break if index >= length
            return false unless evaluate_valid(node.child("prefixItems", index), value[index])
          end
        end

        items = schema["items"]
        if items.is_a?(Array)
          items.each_index do |index|
            break if index >= length
            return false unless evaluate_valid(node.child("items", index), value[index])
          end
          if length > items.length && schema.key?("additionalItems")
            additional = node.child("additionalItems")
            (items.length...length).each do |index|
              return false unless evaluate_valid(additional, value[index])
            end
          end
        elsif !items.nil?
          child = node.child("items")
          start = prefix_items.is_a?(Array) ? prefix_items.length : 0
          (start...length).each do |index|
            return false unless evaluate_valid(child, value[index])
          end
        end

        if schema.key?("contains")
          child = node.child("contains")
          if node.dialect.keywords.key?("minContains")
            matches = value.count { |item| evaluate_valid(child, item) }
            return false if matches < schema.fetch("minContains", 1)
            return false if schema.key?("maxContains") && matches > schema["maxContains"]
          else
            return false unless value.any? { |item| evaluate_valid(child, item) }
          end
        end
        true
      end

      private def valid_object?(node, value)
        schema = node.schema
        length = value.length
        return false if schema.key?("maxProperties") && length > schema["maxProperties"]
        return false if schema.key?("minProperties") && length < schema["minProperties"]
        return false if schema.key?("required") && !schema["required"].all? { |name| value.key?(name) }

        properties = schema["properties"]
        patterns = schema["patternProperties"]
        additional = node.child("additionalProperties") if schema.key?("additionalProperties")
        value.each do |name, property_value|
          matched = false
          if properties&.key?(name)
            matched = true
            return false unless evaluate_valid(node.child("properties", name), property_value)
          end
          if patterns
            patterns.each_key do |pattern|
              next unless ecma_regexp(pattern).match?(name)
              matched = true
              return false unless evaluate_valid(node.child("patternProperties", pattern), property_value)
            end
          end
          return false if !matched && additional && !evaluate_valid(additional, property_value)
        end

        if schema.key?("propertyNames")
          child = node.child("propertyNames")
          value.each_key { |name| return false unless evaluate_valid(child, name) }
        end

        if schema.key?("dependencies")
          schema["dependencies"].each do |name, dependency|
            next unless value.key?(name)
            if dependency.is_a?(Array)
              return false unless dependency.all? { |required_name| value.key?(required_name) }
            else
              return false unless evaluate_valid(node.child("dependencies", name), value)
            end
          end
        end
        if schema.key?("dependentRequired")
          schema["dependentRequired"].each do |name, required_names|
            next unless value.key?(name)
            return false unless required_names.all? { |required_name| value.key?(required_name) }
          end
        end

        if schema.key?("dependentSchemas")
          schema["dependentSchemas"].each_key do |name|
            next unless value.key?(name)
            return false unless evaluate_valid(node.child("dependentSchemas", name), value)
          end
        end
        true
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
        evaluation = Evaluation.valid

        if @track_dynamic_scope
          entered_scope = @dynamic_scope.nil? || !@dynamic_scope.last.equal?(node.resource)
          (@dynamic_scope ||= []) << node.resource if entered_scope
        end

        if schema.key?("$ref")
          begin
            target = @graph.resolve(node, schema["$ref"])
            evaluation = evaluation.merge(
              evaluate_reference(node, target, instance, instance_path, schema_path, "$ref")
            )
          rescue ResolutionError => e
            add_error("$ref", instance_path, schema_path, e.message)
          end
          return (@error_count == before) ? evaluation : Evaluation.invalid unless node.dialect.ref_siblings?
        end

        if schema.key?("$recursiveRef")
          target = recursive_target(node, schema["$recursiveRef"])
          evaluation = evaluation.merge(evaluate_reference(node, target, instance, instance_path, schema_path, "$recursiveRef"))
        end

        if schema.key?("$dynamicRef")
          target = dynamic_target(node, schema["$dynamicRef"])
          evaluation = evaluation.merge(evaluate_reference(node, target, instance, instance_path, schema_path, "$dynamicRef"))
        end

        keywords = node.keyword_mask
        categories = Internal::Dialect
        check_type(schema, instance, instance_path, schema_path) if (keywords & categories::TYPE) != 0
        check_enum(schema, instance, instance_path, schema_path) if (keywords & categories::ENUM) != 0
        if (keywords & categories::COMBINER) != 0
          evaluation = evaluation.merge(check_combiners(node, instance, instance_path, schema_path))
        end

        case instance
        when Hash
          if (keywords & categories::OBJECT) != 0
            evaluation = evaluation.merge(check_object(node, instance, instance_path, schema_path, evaluation))
          end
        when Array
          if (keywords & categories::ARRAY) != 0
            evaluation = evaluation.merge(check_array(node, instance, instance_path, schema_path, evaluation))
          end
        when String
          check_string(node, instance, instance_path, schema_path) if (keywords & categories::STRING) != 0 || format_asserted?(node)
        when Numeric
          check_number(schema, instance, instance_path, schema_path) if !instance.is_a?(Complex) && (keywords & categories::NUMBER) != 0
        end

        (@error_count == before) ? evaluation : Evaluation.invalid
      ensure
        @dynamic_scope.pop if entered_scope
      end

      private def evaluate_reference(node, target, instance, instance_path, schema_path, keyword)
        instances = active_instances(node)
        instance_id = instance.object_id
        return Evaluation.valid if instances[instance_id]

        instances[instance_id] = true
        activated = true
        evaluate(target, instance, instance_path, append(schema_path, keyword))
      rescue ResolutionError => e
        add_error(keyword, instance_path, schema_path, e.message)
        Evaluation.invalid
      ensure
        instances&.delete(instance_id) if activated
      end

      private def recursive_target(node, reference)
        target = @graph.resolve(node, reference)
        return target unless reference.to_s.end_with?("#") && target.schema.is_a?(Hash) && target.schema["$recursiveAnchor"] == true

        @dynamic_scope.filter_map { |resource| resource.root if resource.root.schema.is_a?(Hash) && resource.root.schema["$recursiveAnchor"] == true }.first || target
      end

      private def dynamic_target(node, reference)
        target = @graph.resolve(node, reference)
        raw_fragment = reference.to_s.split("#", 2)[1]
        return target if raw_fragment.nil? || raw_fragment.empty? || raw_fragment.start_with?("/")
        return target unless target.schema.is_a?(Hash) && target.schema["$dynamicAnchor"] == raw_fragment

        @dynamic_scope.each do |resource|
          dynamic = @graph.dynamic_anchor(resource, raw_fragment)
          return dynamic if dynamic
        end
        target
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
        evaluation = Evaluation.valid
        if schema.key?("allOf")
          schema["allOf"].each_index do |index|
            evaluation = evaluation.merge(
              evaluate(node.child("allOf", index), value, path, append(append(schema_path, "allOf"), index))
            )
          end
        end

        if schema.key?("anyOf")
          matches = []
          schema["anyOf"].each_index do |index|
            result = trial(node.child("anyOf", index), value, path, append(append(schema_path, "anyOf"), index))
            matches << result if result.valid?
          end
          if matches.empty?
            add_error("anyOf", path, append(schema_path, "anyOf"), "no subschema matched")
          else
            matches.each { |result| evaluation = evaluation.merge(result) }
          end
        end

        if schema.key?("oneOf")
          matches = []
          schema["oneOf"].each_index do |index|
            result = trial(node.child("oneOf", index), value, path, append(append(schema_path, "oneOf"), index))
            matches << result if result.valid?
          end
          if matches.length == 1
            evaluation = evaluation.merge(matches.first)
          else
            add_error("oneOf", path, append(schema_path, "oneOf"), "expected exactly one match, got #{matches.length}")
          end
        end

        if schema.key?("not") && trial(node.child("not"), value, path, append(schema_path, "not")).valid?
          add_error("not", path, append(schema_path, "not"), "subschema matched")
        end

        if schema.key?("if")
          condition = trial(node.child("if"), value, path, append(schema_path, "if"))
          branch = condition.valid? ? "then" : "else"
          evaluation = evaluation.merge(condition) if condition.valid?
          if schema.key?(branch)
            evaluation = evaluation.merge(evaluate(node.child(branch), value, path, append(schema_path, branch)))
          end
        end
        evaluation
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

      private def check_string(node, value, path, schema_path)
        schema = node.schema
        length = value.length
        limit(schema, "maxLength", length, path, schema_path) { |actual, expected| actual <= expected }
        limit(schema, "minLength", length, path, schema_path) { |actual, expected| actual >= expected }

        if schema.key?("pattern")
          matched = ecma_regexp(schema["pattern"]).match?(value)
          add_error("pattern", path, append(schema_path, "pattern"), "string does not match pattern") unless matched
        end
        if format_asserted?(node)
          add_error("format", path, append(schema_path, "format"), "string is not a valid #{node.format.name}") unless node.format.call(value)
        end
        check_content(schema, value, path, schema_path) if @validate_content
      rescue RegexpError
        add_error("pattern", path, append(schema_path, "pattern"), "invalid regular expression")
      end

      private def format_asserted?(node)
        (@validate_format || node.dialect.format_assertion?) && !node.format.nil?
      end

      private def check_array(node, value, path, schema_path, prior_evaluation)
        schema = node.schema
        evaluated = []
        limit(schema, "maxItems", value.length, path, schema_path) { |actual, expected| actual <= expected }
        limit(schema, "minItems", value.length, path, schema_path) { |actual, expected| actual >= expected }

        if schema["uniqueItems"]
          duplicate = value.each_with_index.any? do |item, index|
            value[0...index].any? { |previous| json_equal?(previous, item) }
          end
          add_error("uniqueItems", path, append(schema_path, "uniqueItems"), "array items are not unique") if duplicate
        end

        prefix_items = schema["prefixItems"]
        if prefix_items.is_a?(Array)
          prefix_items.each_index do |index|
            break if index >= value.length
            evaluate(node.child("prefixItems", index), value[index], append(path, index), append(append(schema_path, "prefixItems"), index))
            evaluated << index
          end
        end

        items = schema["items"]
        if items.is_a?(Array)
          items.each_index do |index|
            break if index >= value.length
            evaluate(node.child("items", index), value[index], append(path, index), append(append(schema_path, "items"), index))
            evaluated << index
          end
          if value.length > items.length && schema.key?("additionalItems")
            additional = node.child("additionalItems")
            (items.length...value.length).each do |index|
              evaluate(additional, value[index], append(path, index), append(schema_path, "additionalItems"))
              evaluated << index
            end
          end
        elsif !items.nil?
          start = prefix_items.is_a?(Array) ? prefix_items.length : 0
          value.each_with_index do |item, index|
            next if index < start
            evaluate(node.child("items"), item, append(path, index), append(schema_path, "items"))
            evaluated << index
          end
        end

        if schema.key?("contains")
          matched = value.each_index.select do |index|
            trial(node.child("contains"), value[index], append(path, index), append(schema_path, "contains")).valid?
          end
          minimum = schema.fetch("minContains", 1)
          maximum = schema.fetch("maxContains", Float::INFINITY)
          unless matched.length.between?(minimum, maximum)
            add_error("contains", path, append(schema_path, "contains"), "matched #{matched.length} array items")
          end
          evaluated.concat(matched)
        end

        combined = prior_evaluation.evaluated_items | evaluated
        if schema.key?("unevaluatedItems")
          unevaluated = (0...value.length).to_a - combined
          unevaluated.each do |index|
            evaluate(node.child("unevaluatedItems"), value[index], append(path, index), append(schema_path, "unevaluatedItems"))
          end
          evaluated.concat(unevaluated)
        end
        Evaluation.valid(evaluated_items: evaluated.uniq)
      end

      private def check_object(node, value, path, schema_path, prior_evaluation)
        schema = node.schema
        evaluated = []
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
            evaluate(node.child("properties", name), property_value, append(path, name), append(append(schema_path, "properties"), name))
            evaluated << name
          end
          patterns.each do |pattern, subschema|
            next unless ecma_regexp(pattern).match?(name)
            matched = true
            evaluate(node.child("patternProperties", pattern), property_value, append(path, name), append(append(schema_path, "patternProperties"), pattern))
            evaluated << name
          end
          if !matched && schema.key?("additionalProperties")
            evaluate(node.child("additionalProperties"), property_value, append(path, name), append(schema_path, "additionalProperties"))
            evaluated << name
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
            result = evaluate(node.child("dependencies", name), value, path, append(append(schema_path, "dependencies"), name))
            evaluated.concat(result.evaluated_properties) if result.valid?
          end
        end

        schema.fetch("dependentRequired", {}).each do |name, required_names|
          next unless value.key?(name)
          required_names.each do |required_name|
            unless value.key?(required_name)
              add_error("dependentRequired", path, append(schema_path, "dependentRequired"), "property #{required_name.inspect} is required by #{name.inspect}")
            end
          end
        end

        schema.fetch("dependentSchemas", {}).each_key do |name|
          next unless value.key?(name)
          result = evaluate(node.child("dependentSchemas", name), value, path, append(append(schema_path, "dependentSchemas"), name))
          evaluated.concat(result.evaluated_properties) if result.valid?
        end

        combined = prior_evaluation.evaluated_properties | evaluated
        if schema.key?("unevaluatedProperties")
          unevaluated = value.keys - combined
          unevaluated.each do |name|
            evaluate(node.child("unevaluatedProperties"), value[name], append(path, name), append(schema_path, "unevaluatedProperties"))
          end
          evaluated.concat(unevaluated)
        end
        Evaluation.valid(evaluated_properties: evaluated.uniq)
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
        @errors << ValidationError.new(keyword: keyword, instance_path: instance_path, schema_path: schema_path, message: message) if @errors
        false
      end

      private def append(path, segment)
        return if path.nil?

        "#{path}/#{segment.to_s.gsub("~", "~0").gsub("/", "~1")}"
      end
    end
  end

  class Validator
    def initialize(schema = nil, content: false, format: false, **schema_keywords)
      schema = schema_keywords unless schema_keywords.empty?
      unless schema.is_a?(CompiledSchema)
        raise ArgumentError, "schema must be compiled by SchemaRegistry#compile"
      end

      @evaluator = Internal::Evaluator.new(schema, content: content, format: format)
    end

    def validate(instance)
      @evaluator.validate(instance)
    end

    def valid?(instance)
      @evaluator.valid?(instance)
    end
  end

  module_function def compile(*args, schemas: {}, base_uri: nil, **schema_keywords)
    SchemaRegistry.new(schemas: schemas).compile(*args, base_uri: base_uri, **schema_keywords)
  end

  module_function def validate(schema, instance, schemas: {}, base_uri: nil, content: false, format: false)
    compiled = compile(schema, schemas: schemas, base_uri: base_uri)
    Validator.new(compiled, content: content, format: format).validate(instance)
  end

  module_function def valid?(schema, instance, schemas: {}, base_uri: nil, content: false, format: false)
    compiled = compile(schema, schemas: schemas, base_uri: base_uri)
    Validator.new(compiled, content: content, format: format).valid?(instance)
  end
end
