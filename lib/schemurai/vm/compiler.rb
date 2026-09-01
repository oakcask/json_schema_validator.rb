# frozen_string_literal: true

module Schemurai
  module VM
    NumberRules = Data.define(
      :mask,
      :maximum,
      :minimum,
      :exclusive_maximum,
      :exclusive_minimum,
      :multiple_of
    )

    MAXIMUM = 1 << 0
    MINIMUM = 1 << 1
    EXCLUSIVE_MAXIMUM = 1 << 2
    EXCLUSIVE_MINIMUM = 1 << 3
    MULTIPLE_OF = 1 << 4

    TypeRules = Data.define(:mask, :names)

    TYPE_NULL = 1 << 0
    TYPE_BOOLEAN = 1 << 1
    TYPE_OBJECT = 1 << 2
    TYPE_ARRAY = 1 << 3
    TYPE_NUMBER = 1 << 4
    TYPE_INTEGER = 1 << 5
    TYPE_STRING = 1 << 6

    TYPE_BITS = {
      "null" => TYPE_NULL,
      "boolean" => TYPE_BOOLEAN,
      "object" => TYPE_OBJECT,
      "array" => TYPE_ARRAY,
      "number" => TYPE_NUMBER,
      "integer" => TYPE_INTEGER,
      "string" => TYPE_STRING
    }.freeze

    TYPE_OPCODES = {
      "null" => :type_null,
      "boolean" => :type_boolean,
      "object" => :type_object,
      "array" => :type_array,
      "number" => :type_number,
      "integer" => :type_integer,
      "string" => :type_string
    }.freeze

    ReferenceRules = Data.define(:value, :fragment)

    StringRules = Data.define(
      :max_length,
      :has_max_length,
      :min_length,
      :has_min_length,
      :pattern,
      :has_pattern,
      :format,
      :format_assertion,
      :decode_base64,
      :parse_json
    )

    ArrayRules = Data.define(
      :max_items,
      :has_max_items,
      :min_items,
      :has_min_items,
      :unique,
      :prefix_items,
      :items,
      :items_list,
      :additional,
      :contains,
      :min_contains,
      :max_contains,
      :count_contains,
      :unevaluated
    )

    ObjectRules = Data.define(
      :max_properties,
      :has_max_properties,
      :min_properties,
      :has_min_properties,
      :required,
      :has_required,
      :properties,
      :patterns,
      :additional,
      :property_names,
      :dependencies,
      :dependent_required,
      :dependent_schemas,
      :unevaluated
    )

    ConditionalRules = Data.define(
      :condition,
      :then_branch,
      :else_branch,
      :has_then,
      :has_else
    )

    class Program
      attr_reader :node, :code, :dynamic_anchor

      def initialize(node)
        @node = node
        schema = node.schema
        @recursive_anchor = schema.is_a?(Hash) && schema["$recursiveAnchor"] == true
        @dynamic_anchor = if schema.is_a?(Hash) && schema["$dynamicAnchor"].is_a?(String)
          schema["$dynamicAnchor"].dup.freeze
        end
      end

      def finish(code)
        @code = code.map(&:freeze).freeze
        @tracks_evaluation = code.any? do |instruction|
          %i[array object].include?(instruction.first) && instruction[1].unevaluated
        end
        @tracks_dynamic_scope = code.any? do |opcode, operand|
          opcode == :ref || opcode == :recursive_ref || opcode == :dynamic_ref || dynamic_scope_operand?(operand)
        end
        freeze
      end

      def tracks_evaluation?
        @tracks_evaluation
      end

      def recursive_anchor?
        @recursive_anchor
      end

      def tracks_dynamic_scope?
        @tracks_dynamic_scope
      end

      private def dynamic_scope_operand?(operand)
        case operand
        when Program
          operand.tracks_dynamic_scope?
        when Array
          operand.any? { |item| dynamic_scope_operand?(item) }
        when Hash
          operand.each_value { |item| return true if dynamic_scope_operand?(item) }
          false
        when ArrayRules
          dynamic_scope_operand?(operand.prefix_items) ||
            dynamic_scope_operand?(operand.items) ||
            dynamic_scope_operand?(operand.additional) ||
            dynamic_scope_operand?(operand.contains) ||
            dynamic_scope_operand?(operand.unevaluated)
        when ObjectRules
          dynamic_scope_operand?(operand.properties) ||
            dynamic_scope_operand?(operand.patterns) ||
            dynamic_scope_operand?(operand.additional) ||
            dynamic_scope_operand?(operand.property_names) ||
            dynamic_scope_operand?(operand.dependencies) ||
            dynamic_scope_operand?(operand.dependent_schemas) ||
            dynamic_scope_operand?(operand.unevaluated)
        when ConditionalRules
          dynamic_scope_operand?(operand.condition) ||
            dynamic_scope_operand?(operand.then_branch) ||
            dynamic_scope_operand?(operand.else_branch)
        else
          false
        end
      end
    end

    class Compiler
      def initialize(graph)
        @graph = graph
        @programs = {}.compare_by_identity
      end

      def compile(node)
        @programs.fetch(node) do
          program = Program.new(node)
          @programs[node] = program
          program.finish(compile_code(node))
        end
      end

      def resolve(program, reference)
        compile(@graph.resolve(program.node, reference))
      end

      private def compile_code(node)
        schema = node.schema
        return [[:boolean, schema]] if schema == true || schema == false
        return [] unless schema.is_a?(Hash)

        code = []
        if schema.key?("$ref")
          code << [:ref, compile_reference(schema["$ref"])]
          return code unless node.dialect.ref_siblings?
        end
        code << [:recursive_ref, compile_reference(schema["$recursiveRef"])] if schema.key?("$recursiveRef")
        code << [:dynamic_ref, compile_reference(schema["$dynamicRef"])] if schema.key?("$dynamicRef")

        mask = node.keyword_mask
        categories = Schemurai.const_get(:Internal)::Dialect
        code << compile_type(schema["type"]) if (mask & categories::TYPE) != 0 && schema.key?("type")
        if (mask & categories::ENUM) != 0
          code << [:enum, snapshot(schema["enum"])] if schema.key?("enum")
          code << [:const, snapshot(schema["const"])] if schema.key?("const")
        end
        compile_combiners(code, node, schema) if (mask & categories::COMBINER) != 0
        code << [:number, compile_number(schema)] if (mask & categories::NUMBER) != 0
        if (mask & categories::STRING) != 0 || node.format
          code << [:string, compile_string(node, schema)]
        end
        code << [:array, compile_array(node, schema)] if (mask & categories::ARRAY) != 0
        code << [:object, compile_object(node, schema)] if (mask & categories::OBJECT) != 0
        code
      end

      private def compile_combiners(code, node, schema)
        %w[allOf anyOf oneOf].each do |keyword|
          next unless schema.key?(keyword)

          children = schema[keyword].each_index.map { |index| compile(node.child(keyword, index)) }
          code << [keyword.to_sym, children]
        end
        code << [:not, compile(node.child("not"))] if schema.key?("not")
        return unless schema.key?("if")

        code << [
          :conditional,
          ConditionalRules.new(
            compile(node.child("if")),
            schema.key?("then") ? compile(node.child("then")) : nil,
            schema.key?("else") ? compile(node.child("else")) : nil,
            schema.key?("then"),
            schema.key?("else")
          )
        ]
      end

      private def compile_number(schema)
        mask = 0
        mask |= MAXIMUM if schema.key?("maximum")
        mask |= MINIMUM if schema.key?("minimum")
        mask |= EXCLUSIVE_MAXIMUM if schema.key?("exclusiveMaximum")
        mask |= EXCLUSIVE_MINIMUM if schema.key?("exclusiveMinimum")
        mask |= MULTIPLE_OF if schema.key?("multipleOf")
        NumberRules.new(
          mask: mask,
          maximum: compile_decimal(schema["maximum"]),
          minimum: compile_decimal(schema["minimum"]),
          exclusive_maximum: compile_decimal(schema["exclusiveMaximum"]),
          exclusive_minimum: compile_decimal(schema["exclusiveMinimum"]),
          multiple_of: compile_decimal(schema["multipleOf"])
        )
      end

      private def compile_reference(reference)
        value = snapshot(reference)
        separator = value.index("#")
        fragment = separator ? value[(separator + 1)..].freeze : nil
        ReferenceRules.new(value: value, fragment: fragment)
      end

      private def compile_type(types)
        return [TYPE_OPCODES.fetch(types)] unless types.is_a?(Array)

        mask = types.reduce(0) { |result, type| result | TYPE_BITS.fetch(type) }
        [:types, TypeRules.new(mask: mask, names: snapshot(types))]
      end

      private def compile_string(node, schema)
        StringRules.new(
          schema["maxLength"],
          schema.key?("maxLength"),
          schema["minLength"],
          schema.key?("minLength"),
          snapshot(schema["pattern"]),
          schema.key?("pattern"),
          node.format,
          node.dialect.format_assertion?,
          schema["contentEncoding"] == "base64",
          schema["contentMediaType"] == "application/json"
        )
      end

      private def compile_array(node, schema)
        prefix_items = if schema["prefixItems"].is_a?(Array)
          schema["prefixItems"].each_index.map { |index| compile(node.child("prefixItems", index)) }.freeze
        end
        items = if schema["items"].is_a?(Array)
          schema["items"].each_index.map { |index| compile(node.child("items", index)) }.freeze
        elsif !schema["items"].nil?
          compile(node.child("items"))
        end
        ArrayRules.new(
          schema["maxItems"],
          schema.key?("maxItems"),
          schema["minItems"],
          schema.key?("minItems"),
          schema["uniqueItems"],
          prefix_items,
          items,
          items.is_a?(Array),
          schema.key?("additionalItems") ? compile(node.child("additionalItems")) : nil,
          schema.key?("contains") ? compile(node.child("contains")) : nil,
          schema.fetch("minContains", 1),
          schema.fetch("maxContains", Float::INFINITY),
          node.dialect.keywords.key?("minContains"),
          schema.key?("unevaluatedItems") ? compile(node.child("unevaluatedItems")) : nil
        )
      end

      private def compile_object(node, schema)
        ObjectRules.new(
          schema["maxProperties"],
          schema.key?("maxProperties"),
          schema["minProperties"],
          schema.key?("minProperties"),
          snapshot(schema["required"]),
          schema.key?("required"),
          compile_map(node, schema, "properties"),
          compile_map(node, schema, "patternProperties"),
          schema.key?("additionalProperties") ? compile(node.child("additionalProperties")) : nil,
          schema.key?("propertyNames") ? compile(node.child("propertyNames")) : nil,
          compile_dependencies(node, schema),
          schema.fetch("dependentRequired", {}).map do |name, required_names|
            [snapshot(name), snapshot(required_names)].freeze
          end.freeze,
          compile_map(node, schema, "dependentSchemas"),
          schema.key?("unevaluatedProperties") ? compile(node.child("unevaluatedProperties")) : nil
        )
      end

      private def compile_map(node, schema, keyword)
        schema.fetch(keyword, {}).each_key.to_h do |name|
          [snapshot(name), compile(node.child(keyword, name))]
        end.freeze
      end

      private def compile_dependencies(node, schema)
        schema.fetch("dependencies", {}).map do |name, dependency|
          compiled = dependency.is_a?(Array) ? snapshot(dependency) : compile(node.child("dependencies", name))
          [snapshot(name), compiled].freeze
        end.freeze
      end

      private def snapshot(value)
        case value
        when Hash
          value.to_h { |key, item| [snapshot(key), snapshot(item)] }.freeze
        when Array
          value.map { |item| snapshot(item) }.freeze
        when String
          value.dup.freeze
        else
          value
        end
      end

      private def compile_decimal(value)
        return value if value.nil? || value.is_a?(Integer) || value.is_a?(Rational)

        Rational(value.to_s)
      end
    end
  end
end
