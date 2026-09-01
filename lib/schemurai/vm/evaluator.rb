# frozen_string_literal: true

require "base64"
require "json"
require_relative "../evaluation"
require_relative "compiler"

module Schemurai
  module VM
    class Evaluator
      MISSING_SEGMENT = Object.new.freeze

      def backend = :vm

      def initialize(graph, compiler, root, content: false, format: false)
        @graph = graph
        @compiler = compiler
        @root = root
        @validate_content = content
        @validate_format = format
        @regexps = nil
        @active = nil
      end

      def validate(instance)
        @errors = []
        prepare_evaluation(paths: true)
        evaluate(@root, instance)
        Result.new(@errors)
      ensure
        @errors = nil
      end

      def valid?(instance)
        @errors = nil
        prepare_evaluation(paths: @root.tracks_evaluation?)
        evaluate_valid(@root, instance)
      end

      private def prepare_evaluation(paths:)
        @error_count = 0
        @dynamic_scope = nil
        @instance_path = paths ? [] : nil
        @schema_path = paths ? [] : nil
      end

      private def evaluate_valid(program, instance)
        if program.tracks_evaluation?
          @instance_path ||= []
          @schema_path ||= []
          return evaluate(program, instance).valid?
        end

        entered_scope = enter_scope(program)
        program.code.each do |opcode, operand, extra|
          case opcode
          when :boolean
            return operand
          when :ref
            target = @compiler.resolve(program, operand.value)
            return false unless valid_reference?(program, target, instance)
          when :recursive_ref
            target = recursive_target(program, operand)
            return false unless valid_reference?(program, target, instance)
          when :dynamic_ref
            target = dynamic_target(program, operand)
            return false unless valid_reference?(program, target, instance)
          when :type_null
            return false unless instance.nil?
          when :type_boolean
            return false unless instance == true || instance == false
          when :type_object
            return false unless instance.is_a?(Hash)
          when :type_array
            return false unless instance.is_a?(Array)
          when :type_number
            return false unless number?(instance)
          when :type_integer
            return false unless integer?(instance)
          when :type_string
            return false unless instance.is_a?(String)
          when :types
            return false if (operand.mask & instance_type_mask(instance, integer: (operand.mask & TYPE_INTEGER) != 0)).zero?
          when :enum
            return false unless operand.any? { |candidate| json_equal?(candidate, instance) }
          when :const
            return false unless json_equal?(operand, instance)
          when :allOf
            return false unless operand.all? { |child| evaluate_valid(child, instance) }
          when :anyOf
            return false unless operand.any? { |child| evaluate_valid(child, instance) }
          when :oneOf
            matches = 0
            operand.each do |child|
              matches += 1 if evaluate_valid(child, instance)
              return false if matches > 1
            end
            return false unless matches == 1
          when :not
            return false if evaluate_valid(operand, instance)
          when :conditional
            if evaluate_valid(operand.condition, instance)
              return false if operand.has_then && !evaluate_valid(operand.then_branch, instance)
            elsif operand.has_else && !evaluate_valid(operand.else_branch, instance)
              return false
            end
          when :number
            return false if instance.is_a?(Numeric) && !instance.is_a?(Complex) && !valid_number?(operand, instance)
          when :string
            return false if instance.is_a?(String) && !valid_string?(operand, instance)
          when :array
            return false if instance.is_a?(Array) && !valid_array?(operand, instance)
          when :object
            return false if instance.is_a?(Hash) && !valid_object?(operand, instance)
          else
            raise "unknown VM instruction #{opcode.inspect}"
          end
        end
        true
      rescue ResolutionError
        false
      ensure
        leave_scope if entered_scope
      end

      private def evaluate(program, instance)
        before = @error_count
        evaluation = Evaluation.valid
        entered_scope = enter_scope(program)

        program.code.each do |opcode, operand, extra|
          case opcode
          when :boolean
            if operand == false
              add_error("falseSchema", "boolean schema is false", append_keyword: false)
              evaluation = Evaluation.invalid
            end
          when :ref
            evaluation = evaluation.merge(evaluate_ref(program, operand, instance))
          when :recursive_ref
            evaluation = evaluation.merge(evaluate_recursive_ref(program, operand, instance))
          when :dynamic_ref
            evaluation = evaluation.merge(evaluate_dynamic_ref(program, operand, instance))
          when :type_null
            check_compiled_type("null", instance.nil?)
          when :type_boolean
            check_compiled_type("boolean", instance == true || instance == false)
          when :type_object
            check_compiled_type("object", instance.is_a?(Hash))
          when :type_array
            check_compiled_type("array", instance.is_a?(Array))
          when :type_number
            check_compiled_type("number", number?(instance))
          when :type_integer
            check_compiled_type("integer", integer?(instance))
          when :type_string
            check_compiled_type("string", instance.is_a?(String))
          when :types
            check_compiled_types(operand, instance)
          when :enum
            add_error("enum", "value is not in enum") unless operand.any? { |candidate| json_equal?(candidate, instance) }
          when :const
            add_error("const", "value does not equal const") unless json_equal?(operand, instance)
          when :allOf, :anyOf, :oneOf, :not, :conditional
            evaluation = evaluation.merge(check_combiner(opcode, operand, instance))
          when :number
            check_number(operand, instance) if instance.is_a?(Numeric) && !instance.is_a?(Complex)
          when :string
            check_string(operand, instance) if instance.is_a?(String)
          when :array
            evaluation = evaluation.merge(check_array(operand, instance, evaluation)) if instance.is_a?(Array)
          when :object
            evaluation = evaluation.merge(check_object(operand, instance, evaluation)) if instance.is_a?(Hash)
          else
            raise "unknown VM instruction #{opcode.inspect}"
          end
        end
        (@error_count == before) ? evaluation : Evaluation.invalid
      ensure
        leave_scope if entered_scope
      end

      private def enter_scope(program)
        return false unless program.tracks_dynamic_scope?
        return false if @dynamic_scope&.last.equal?(program.node.resource)

        (@dynamic_scope ||= []) << program.node.resource
        true
      end

      private def leave_scope
        @dynamic_scope.pop
      end

      private def recursive_target(program, rules)
        target = @compiler.resolve(program, rules.value)
        return target unless rules.fragment == "" && target.recursive_anchor?

        dynamic = @dynamic_scope.filter_map do |resource|
          root = resource.root
          compiled = @compiler.compile(root)
          compiled if compiled.recursive_anchor?
        end.first
        dynamic || target
      end

      private def dynamic_target(program, rules)
        target = @compiler.resolve(program, rules.value)
        fragment = rules.fragment
        return target if fragment.nil? || fragment.empty? || fragment.start_with?("/")

        return target unless target.dynamic_anchor == fragment

        @dynamic_scope.each do |resource|
          dynamic = @graph.dynamic_anchor(resource, fragment)
          return @compiler.compile(dynamic) if dynamic
        end
        target
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

      private def evaluate_ref(source, rules, instance)
        target = @compiler.resolve(source, rules.value)
        evaluate_reference(source, target, instance, "$ref")
      rescue ResolutionError => error
        unresolved_reference("$ref", error)
      end

      private def evaluate_recursive_ref(source, rules, instance)
        evaluate_reference(source, recursive_target(source, rules), instance, "$recursiveRef")
      rescue ResolutionError => error
        unresolved_reference("$recursiveRef", error)
      end

      private def evaluate_dynamic_ref(source, rules, instance)
        evaluate_reference(source, dynamic_target(source, rules), instance, "$dynamicRef")
      rescue ResolutionError => error
        unresolved_reference("$dynamicRef", error)
      end

      private def evaluate_reference(source, target, instance, keyword)
        instances = active_instances(source)
        instance_id = instance.object_id
        return Evaluation.valid if instances[instance_id]

        instances[instance_id] = true
        activated = true
        evaluate_at(target, instance, MISSING_SEGMENT, keyword)
      ensure
        instances&.delete(instance_id) if activated
      end

      private def unresolved_reference(keyword, error)
        add_error(keyword, error.message, append_keyword: false)
        Evaluation.invalid
      end

      private def active_instances(program)
        active = (@active ||= {})
        active[program.node.object_id] ||= {}
      end

      private def check_compiled_type(name, valid)
        add_error("type", "expected #{name}") unless valid
      end

      private def check_compiled_types(rules, value)
        instance_mask = instance_type_mask(value, integer: (rules.mask & TYPE_INTEGER) != 0)
        return unless (rules.mask & instance_mask).zero?

        add_error("type", "expected #{rules.names.join(" or ")}")
      end

      private def instance_type_mask(value, integer:)
        return TYPE_NULL if value.nil?
        return TYPE_BOOLEAN if value == true || value == false
        return TYPE_OBJECT if value.is_a?(Hash)
        return TYPE_ARRAY if value.is_a?(Array)
        return TYPE_STRING if value.is_a?(String)
        return 0 unless number?(value)
        return TYPE_NUMBER unless integer

        (value.finite? && value.to_i == value) ? TYPE_NUMBER | TYPE_INTEGER : TYPE_NUMBER
      end

      private def integer?(value)
        number?(value) && value.finite? && value.to_i == value
      end

      private def valid_number?(rules, value)
        mask = rules.mask
        actual = decimal(value)
        return false if (mask & MAXIMUM) != 0 && actual > rules.maximum
        return false if (mask & MINIMUM) != 0 && actual < rules.minimum
        return false if (mask & EXCLUSIVE_MAXIMUM) != 0 && actual >= rules.exclusive_maximum
        return false if (mask & EXCLUSIVE_MINIMUM) != 0 && actual <= rules.exclusive_minimum
        return true if (mask & MULTIPLE_OF).zero?

        rules.multiple_of.positive? && actual.remainder(rules.multiple_of).zero?
      end

      private def check_number(rules, value)
        mask = rules.mask
        actual = decimal(value)
        if (mask & MAXIMUM) != 0 && actual > rules.maximum
          add_error("maximum", "numeric limit was exceeded")
        end
        if (mask & MINIMUM) != 0 && actual < rules.minimum
          add_error("minimum", "numeric limit was exceeded")
        end
        if (mask & EXCLUSIVE_MAXIMUM) != 0 && actual >= rules.exclusive_maximum
          add_error("exclusiveMaximum", "numeric limit was exceeded")
        end
        if (mask & EXCLUSIVE_MINIMUM) != 0 && actual <= rules.exclusive_minimum
          add_error("exclusiveMinimum", "numeric limit was exceeded")
        end
        return if (mask & MULTIPLE_OF).zero?

        divisor = rules.multiple_of
        valid = divisor.positive? && actual.remainder(divisor).zero?
        add_error("multipleOf", "number is not a multiple") unless valid
      end

      private def valid_string?(rules, value)
        length = value.length
        return false if rules.has_max_length && length > rules.max_length
        return false if rules.has_min_length && length < rules.min_length
        return false if rules.has_pattern && !ecma_regexp(rules.pattern).match?(value)
        if format_asserted?(rules)
          return false unless rules.format.call(value)
        end
        return valid_content?(rules, value) if @validate_content

        true
      rescue RegexpError, IPAddr::InvalidAddressError
        false
      end

      private def check_string(rules, value)
        length = value.length
        if rules.has_max_length && length > rules.max_length
          add_error("maxLength", "size limit was exceeded")
        end
        if rules.has_min_length && length < rules.min_length
          add_error("minLength", "size limit was exceeded")
        end
        if rules.has_pattern && !ecma_regexp(rules.pattern).match?(value)
          add_error("pattern", "string does not match pattern")
        end
        if format_asserted?(rules) && !rules.format.call(value)
          add_error("format", "string is not a valid #{rules.format.name}")
        end
        check_content(rules, value) if @validate_content
      rescue RegexpError
        add_error("pattern", "invalid regular expression")
      end

      private def format_asserted?(rules)
        (@validate_format || rules.format_assertion) && !rules.format.nil?
      end

      private def valid_content?(rules, value)
        decoded = rules.decode_base64 ? Base64.strict_decode64(value) : value
        JSON.parse(decoded) if rules.parse_json
        true
      rescue ArgumentError, JSON::ParserError
        false
      end

      private def check_content(rules, value)
        decoded = rules.decode_base64 ? Base64.strict_decode64(value) : value
        return unless rules.parse_json

        JSON.parse(decoded)
      rescue ArgumentError, JSON::ParserError
        keyword = rules.decode_base64 ? "contentEncoding" : "contentMediaType"
        add_error(keyword, "string content is invalid")
      end

      private def valid_array?(rules, value)
        length = value.length
        return false if rules.has_max_items && length > rules.max_items
        return false if rules.has_min_items && length < rules.min_items
        if rules.unique
          value.each_with_index do |item, index|
            return false if value[0...index].any? { |previous| json_equal?(previous, item) }
          end
        end

        if (prefix_items = rules.prefix_items)
          prefix_items.each_with_index do |child, index|
            break if index >= length
            return false unless evaluate_valid(child, value[index])
          end
        end

        items = rules.items
        if rules.items_list
          items.each_with_index do |child, index|
            break if index >= length
            return false unless evaluate_valid(child, value[index])
          end
          if length > items.length && (additional = rules.additional)
            (items.length...length).each do |index|
              return false unless evaluate_valid(additional, value[index])
            end
          end
        elsif items
          start = rules.prefix_items&.length || 0
          (start...length).each do |index|
            return false unless evaluate_valid(items, value[index])
          end
        end

        if (contains = rules.contains)
          if rules.count_contains
            matches = value.count { |item| evaluate_valid(contains, item) }
            return false if matches < rules.min_contains || matches > rules.max_contains
          else
            return false unless value.any? { |item| evaluate_valid(contains, item) }
          end
        end
        true
      end

      private def check_array(rules, value, prior_evaluation)
        evaluated = []
        if rules.has_max_items && value.length > rules.max_items
          add_error("maxItems", "size limit was exceeded")
        end
        if rules.has_min_items && value.length < rules.min_items
          add_error("minItems", "size limit was exceeded")
        end
        if rules.unique
          duplicate = value.each_with_index.any? do |item, index|
            value[0...index].any? { |previous| json_equal?(previous, item) }
          end
          add_error("uniqueItems", "array items are not unique") if duplicate
        end

        if (prefix_items = rules.prefix_items)
          prefix_items.each_with_index do |child, index|
            break if index >= value.length
            evaluate_at(child, value[index], index, "prefixItems", index)
            evaluated << index
          end
        end

        items = rules.items
        if rules.items_list
          items.each_with_index do |child, index|
            break if index >= value.length
            evaluate_at(child, value[index], index, "items", index)
            evaluated << index
          end
          if value.length > items.length && (additional = rules.additional)
            (items.length...value.length).each do |index|
              evaluate_at(additional, value[index], index, "additionalItems")
              evaluated << index
            end
          end
        elsif items
          start = rules.prefix_items&.length || 0
          (start...value.length).each do |index|
            evaluate_at(items, value[index], index, "items")
            evaluated << index
          end
        end

        if (contains = rules.contains)
          matched = value.each_index.select do |index|
            trial_at(contains, value[index], index, "contains").valid?
          end
          unless matched.length.between?(rules.min_contains, rules.max_contains)
            add_error("contains", "matched #{matched.length} array items")
          end
          evaluated.concat(matched)
        end

        combined = prior_evaluation.evaluated_items | evaluated
        if (unevaluated = rules.unevaluated)
          ((0...value.length).to_a - combined).each do |index|
            evaluate_at(unevaluated, value[index], index, "unevaluatedItems")
            evaluated << index
          end
        end
        Evaluation.valid(evaluated_items: evaluated.uniq)
      end

      private def valid_object?(rules, value)
        length = value.length
        return false if rules.has_max_properties && length > rules.max_properties
        return false if rules.has_min_properties && length < rules.min_properties
        if rules.has_required && !rules.required.all? { |name| value.key?(name) }
          return false
        end

        properties = rules.properties
        patterns = rules.patterns
        additional = rules.additional
        value.each do |name, property_value|
          matched = false
          if (child = properties[name])
            matched = true
            return false unless evaluate_valid(child, property_value)
          end
          patterns.each do |pattern, child|
            next unless ecma_regexp(pattern).match?(name)
            matched = true
            return false unless evaluate_valid(child, property_value)
          end
          return false if !matched && additional && !evaluate_valid(additional, property_value)
        end

        if (property_names = rules.property_names)
          value.each_key { |name| return false unless evaluate_valid(property_names, name) }
        end
        rules.dependencies.each do |name, dependency|
          next unless value.key?(name)
          if dependency.is_a?(Array)
            return false unless dependency.all? { |required_name| value.key?(required_name) }
          else
            return false unless evaluate_valid(dependency, value)
          end
        end
        rules.dependent_required.each do |name, required_names|
          next unless value.key?(name)
          return false unless required_names.all? { |required_name| value.key?(required_name) }
        end
        rules.dependent_schemas.each do |name, child|
          next unless value.key?(name)
          return false unless evaluate_valid(child, value)
        end
        true
      end

      private def check_object(rules, value, prior_evaluation)
        evaluated = []
        if rules.has_max_properties && value.length > rules.max_properties
          add_error("maxProperties", "size limit was exceeded")
        end
        if rules.has_min_properties && value.length < rules.min_properties
          add_error("minProperties", "size limit was exceeded")
        end
        if (required = rules.required)
          required.each do |name|
            add_error("required", "required property #{name.inspect} is missing") unless value.key?(name)
          end
        end

        properties = rules.properties
        patterns = rules.patterns
        value.each do |name, property_value|
          matched = false
          if (child = properties[name])
            matched = true
            evaluate_at(child, property_value, name, "properties", name)
            evaluated << name
          end
          patterns.each do |pattern, child|
            next unless ecma_regexp(pattern).match?(name)
            matched = true
            evaluate_at(child, property_value, name, "patternProperties", pattern)
            evaluated << name
          end
          if !matched && (additional = rules.additional)
            evaluate_at(additional, property_value, name, "additionalProperties")
            evaluated << name
          end
        end

        if (property_names = rules.property_names)
          value.each_key { |name| evaluate_at(property_names, name, name, "propertyNames") }
        end
        rules.dependencies.each do |name, dependency|
          next unless value.key?(name)
          if dependency.is_a?(Array)
            dependency.each do |required_name|
              unless value.key?(required_name)
                add_error("dependencies", "property #{required_name.inspect} is required by #{name.inspect}")
              end
            end
          else
            result = evaluate_at(dependency, value, MISSING_SEGMENT, "dependencies", name)
            evaluated.concat(result.evaluated_properties) if result.valid?
          end
        end
        rules.dependent_required.each do |name, required_names|
          next unless value.key?(name)
          required_names.each do |required_name|
            unless value.key?(required_name)
              add_error("dependentRequired", "property #{required_name.inspect} is required by #{name.inspect}")
            end
          end
        end
        rules.dependent_schemas.each do |name, child|
          next unless value.key?(name)
          result = evaluate_at(child, value, MISSING_SEGMENT, "dependentSchemas", name)
          evaluated.concat(result.evaluated_properties) if result.valid?
        end

        combined = prior_evaluation.evaluated_properties | evaluated
        if (unevaluated = rules.unevaluated)
          (value.keys - combined).each do |name|
            evaluate_at(unevaluated, value[name], name, "unevaluatedProperties")
            evaluated << name
          end
        end
        Evaluation.valid(evaluated_properties: evaluated.uniq)
      end

      private def check_combiner(opcode, operand, value)
        evaluation = Evaluation.valid
        case opcode
        when :allOf
          operand.each_with_index do |child, index|
            evaluation = evaluation.merge(evaluate_at(child, value, MISSING_SEGMENT, "allOf", index))
          end
        when :anyOf
          matches = operand.each_with_index.filter_map do |child, index|
            result = trial_at(child, value, MISSING_SEGMENT, "anyOf", index)
            result if result.valid?
          end
          if matches.empty?
            add_error("anyOf", "no subschema matched")
          else
            matches.each { |result| evaluation = evaluation.merge(result) }
          end
        when :oneOf
          matches = operand.each_with_index.filter_map do |child, index|
            result = trial_at(child, value, MISSING_SEGMENT, "oneOf", index)
            result if result.valid?
          end
          if matches.length == 1
            evaluation = evaluation.merge(matches.first)
          else
            add_error("oneOf", "expected exactly one match, got #{matches.length}")
          end
        when :not
          add_error("not", "subschema matched") if trial_at(operand, value, MISSING_SEGMENT, "not").valid?
        when :conditional
          condition = trial_at(operand.condition, value, MISSING_SEGMENT, "if")
          evaluation = evaluation.merge(condition) if condition.valid?
          if condition.valid? && operand.has_then
            evaluation = evaluation.merge(evaluate_at(operand.then_branch, value, MISSING_SEGMENT, "then"))
          elsif !condition.valid? && operand.has_else
            evaluation = evaluation.merge(evaluate_at(operand.else_branch, value, MISSING_SEGMENT, "else"))
          end
        end
        evaluation
      end

      private def trial(program, value)
        saved_errors = @errors
        saved_count = @error_count
        @errors = nil
        @error_count = 0
        evaluate(program, value)
      ensure
        @errors = saved_errors
        @error_count = saved_count
      end

      private def evaluate_at(program, instance, instance_segment, schema_segment, child_segment = MISSING_SEGMENT)
        @instance_path << instance_segment unless instance_segment.equal?(MISSING_SEGMENT)
        @schema_path << schema_segment
        @schema_path << child_segment unless child_segment.equal?(MISSING_SEGMENT)
        evaluate(program, instance)
      ensure
        @schema_path.pop unless child_segment.equal?(MISSING_SEGMENT)
        @schema_path.pop
        @instance_path.pop unless instance_segment.equal?(MISSING_SEGMENT)
      end

      private def trial_at(program, instance, instance_segment, schema_segment, child_segment = MISSING_SEGMENT)
        @instance_path << instance_segment unless instance_segment.equal?(MISSING_SEGMENT)
        @schema_path << schema_segment
        @schema_path << child_segment unless child_segment.equal?(MISSING_SEGMENT)
        trial(program, instance)
      ensure
        @schema_path.pop unless child_segment.equal?(MISSING_SEGMENT)
        @schema_path.pop
        @instance_path.pop unless instance_segment.equal?(MISSING_SEGMENT)
      end

      private def add_error(keyword, message, append_keyword: true)
        @error_count += 1
        return false unless @errors

        final_segment = append_keyword ? keyword : MISSING_SEGMENT
        @errors << ValidationError.new(
          keyword: keyword,
          instance_path: pointer(@instance_path),
          schema_path: pointer(@schema_path, final_segment),
          message: message
        )
        false
      end

      private def number?(value)
        value.is_a?(Numeric) && !value.is_a?(Complex)
      end

      private def json_equal?(left, right)
        return false if json_kind(left) != json_kind(right)
        case left
        when Hash
          left.length == right.length && left.all? do |key, value|
            right.key?(key) && json_equal?(value, right[key])
          end
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

      private def pointer(path, final_segment = MISSING_SEGMENT)
        result = +""
        path.each { |segment| append_pointer_segment(result, segment) }
        append_pointer_segment(result, final_segment) unless final_segment.equal?(MISSING_SEGMENT)
        result
      end

      private def append_pointer_segment(pointer, segment)
        pointer << "/" << segment.to_s.gsub("~", "~0").gsub("/", "~1")
      end

      private_constant :MISSING_SEGMENT
    end
  end

  private_constant :VM
end
