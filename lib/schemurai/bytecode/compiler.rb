# frozen_string_literal: true

module Schemurai
  module Bytecode
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
          %i[array object].include?(instruction.first) && instruction[1][:unevaluated]
        end
        freeze
      end

      def tracks_evaluation?
        @tracks_evaluation
      end

      def recursive_anchor?
        @recursive_anchor
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
          code << [:reference, "$ref", snapshot(schema["$ref"])]
          return code unless node.dialect.ref_siblings?
        end
        code << [:reference, "$recursiveRef", snapshot(schema["$recursiveRef"])] if schema.key?("$recursiveRef")
        code << [:reference, "$dynamicRef", snapshot(schema["$dynamicRef"])] if schema.key?("$dynamicRef")

        mask = node.keyword_mask
        categories = Schemurai.const_get(:Internal)::Dialect
        code << [:type, snapshot(schema["type"])] if (mask & categories::TYPE) != 0 && schema.key?("type")
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

        branches = {if: compile(node.child("if"))}
        branches[:then] = compile(node.child("then")) if schema.key?("then")
        branches[:else] = compile(node.child("else")) if schema.key?("else")
        code << [:conditional, branches.freeze]
      end

      private def compile_number(schema)
        comparisons = %w[maximum minimum exclusiveMaximum exclusiveMinimum].filter_map do |keyword|
          [keyword, snapshot(schema[keyword])].freeze if schema.key?(keyword)
        end
        {
          comparisons: comparisons.freeze,
          multiple_of: snapshot(schema["multipleOf"]),
          has_multiple_of: schema.key?("multipleOf")
        }.freeze
      end

      private def compile_string(node, schema)
        {
          max_length: schema["maxLength"],
          has_max_length: schema.key?("maxLength"),
          min_length: schema["minLength"],
          has_min_length: schema.key?("minLength"),
          pattern: snapshot(schema["pattern"]),
          has_pattern: schema.key?("pattern"),
          format: node.format,
          format_assertion: node.dialect.format_assertion?,
          content_encoding: snapshot(schema["contentEncoding"]),
          content_media_type: snapshot(schema["contentMediaType"])
        }.freeze
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
        {
          max_items: schema["maxItems"],
          has_max_items: schema.key?("maxItems"),
          min_items: schema["minItems"],
          has_min_items: schema.key?("minItems"),
          unique: schema["uniqueItems"],
          prefix_items: prefix_items,
          items: items,
          items_list: items.is_a?(Array),
          additional: schema.key?("additionalItems") ? compile(node.child("additionalItems")) : nil,
          contains: schema.key?("contains") ? compile(node.child("contains")) : nil,
          min_contains: schema.fetch("minContains", 1),
          max_contains: schema.fetch("maxContains", Float::INFINITY),
          count_contains: node.dialect.keywords.key?("minContains"),
          unevaluated: schema.key?("unevaluatedItems") ? compile(node.child("unevaluatedItems")) : nil
        }.freeze
      end

      private def compile_object(node, schema)
        {
          max_properties: schema["maxProperties"],
          has_max_properties: schema.key?("maxProperties"),
          min_properties: schema["minProperties"],
          has_min_properties: schema.key?("minProperties"),
          required: snapshot(schema["required"]),
          has_required: schema.key?("required"),
          properties: compile_map(node, schema, "properties"),
          patterns: compile_map(node, schema, "patternProperties"),
          additional: schema.key?("additionalProperties") ? compile(node.child("additionalProperties")) : nil,
          property_names: schema.key?("propertyNames") ? compile(node.child("propertyNames")) : nil,
          dependencies: compile_dependencies(node, schema),
          dependent_required: schema.fetch("dependentRequired", {}).map do |name, required_names|
            [snapshot(name), snapshot(required_names)].freeze
          end.freeze,
          dependent_schemas: compile_map(node, schema, "dependentSchemas"),
          unevaluated: schema.key?("unevaluatedProperties") ? compile(node.child("unevaluatedProperties")) : nil
        }.freeze
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
    end
  end
end
