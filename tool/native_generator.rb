# frozen_string_literal: true

require "digest"
require "json"
require "prism"

module Schemurai
  module NativeGenerator
    VERSION = 1

    class GenerationError < StandardError; end

    module_function def root
      Pathname(__dir__).join("..").expand_path
    end

    module_function def load_json(path)
      JSON.parse(root.join(path).read)
    end

    module_function def validate_manifests!
      ir = load_json("native/lowering_ir.json")
      intrinsics = load_json("native/intrinsics.json")
      units = load_json("native/translation_units.json")
      raise GenerationError, "lowering IR version must be 1" unless ir.fetch("version") == 1
      raise GenerationError, "intrinsic manifest version must be 1" unless intrinsics.fetch("version") == 1
      raise GenerationError, "translation-unit manifest version must be 1" unless units.fetch("version") == 1

      known_types = ir.fetch("types").keys
      units.fetch("units").each do |unit|
        source = root.join(unit.fetch("source"))
        raise GenerationError, "missing translation source #{unit.fetch("source")}" unless source.file?

        parsed_source = Prism.parse(source.read)
        raise GenerationError, "invalid translation source #{unit.fetch("source")}" unless parsed_source.success?
        available_methods = method_names(parsed_source.value)

        unit.fetch("roots").each do |entry|
          raise GenerationError, "unnamed translation root in #{unit.fetch("name")}" unless entry.key?("root")
          unless available_methods.include?(entry.fetch("method").to_sym)
            raise GenerationError, "missing method #{entry.fetch("method")} in #{unit.fetch("source")}"
          end
          types = entry.fetch("entry") + [entry.fetch("result")]
          unknown = types - known_types
          raise GenerationError, "unknown IR type #{unknown.first} in #{unit.fetch("name")}" unless unknown.empty?
        end
      end

      required = %w[name ruby_forms operands result ruby_semantics c_lowering allocates invokes_ruby raises triggers_gc gvl cleanup rooting restriction refinement guard dispatch available fixtures]
      entries = intrinsics.fetch("intrinsics") + intrinsics.fetch("graph_intrinsics")
      names = entries.map { |entry| entry.fetch("name") }
      raise GenerationError, "intrinsic names must be unique" unless names.uniq == names

      entries.each do |intrinsic|
        missing = required.reject { |field| intrinsic.key?(field) }
        raise GenerationError, "intrinsic #{intrinsic.fetch("name")} lacks #{missing.join(", ")}" unless missing.empty?

        types = intrinsic.fetch("operands") + [intrinsic.fetch("result")]
        types << intrinsic.fetch("receiver") if intrinsic.key?("receiver")
        unknown = types - known_types
        raise GenerationError, "unknown IR type #{unknown.first} in #{intrinsic.fetch("name")}" unless unknown.empty?

        unavailable = intrinsics.fetch("supported_cruby") - intrinsic.fetch("available")
        unless unavailable.empty?
          raise GenerationError, "intrinsic #{intrinsic.fetch("name")} is unavailable on CRuby #{unavailable.first}"
        end
      end

      compatibility_ids = load_json("oracle/compatibility_cases.json").fetch("out_of_domain")
        .map { |fixture| fixture.fetch("id") }
      intrinsics.fetch("generic_calls").each do |call_site|
        required_call_fields = %w[site source method classification fixtures]
        missing = required_call_fields.reject { |field| call_site.key?(field) }
        raise GenerationError, "generic call site lacks #{missing.join(", ")}" unless missing.empty?
        unless call_site.fetch("classification") == "cold_out_of_domain_compatibility"
          raise GenerationError, "generic call #{call_site.fetch("site")} is not a cold compatibility call"
        end

        unknown_fixtures = call_site.fetch("fixtures") - compatibility_ids
        unless unknown_fixtures.empty?
          raise GenerationError, "unknown compatibility fixture #{unknown_fixtures.first}"
        end
      end

      true
    end

    module_function def compile(source, source_name: "(source)")
      result = Prism.parse(source)
      unless result.success?
        failure = result.errors.first
        raise GenerationError, "#{source_name}:#{failure.location.start_line}: #{failure.message}"
      end

      method = find_method(result.value, :boolean_instance?)
      raise GenerationError, "#{source_name}: missing translation root boolean_instance?" unless method

      validate_signature!(method, source_name)
      expressions = method.body&.body || []
      unless expressions.length == 1
        raise GenerationError, "#{source_name}:#{method.location.start_line}: boolean_instance? must contain one expression"
      end
      expression = expressions.first
      lowered = lower(expression, source_name)
      {name: method.name, parameters: [:instance], result: :c_boolean, expression: lowered}
    end

    module_function def generate(output)
      validate_manifests!
      source_path = root.join("native/source/bootstrap.rb")
      ir = compile(source_path.read, source_name: "native/source/bootstrap.rb")
      fingerprints = {
        "generator" => Digest::SHA256.file(__FILE__).hexdigest,
        "source" => Digest::SHA256.file(source_path).hexdigest,
        "intrinsics" => Digest::SHA256.file(root.join("native/intrinsics.json")).hexdigest,
        "lowering_ir" => Digest::SHA256.file(root.join("native/lowering_ir.json")).hexdigest,
        "translation_units" => Digest::SHA256.file(root.join("native/translation_units.json")).hexdigest,
        "prism" => Prism::VERSION,
        "generator_version" => VERSION.to_s
      }
      body = emit(ir, fingerprints)
      Pathname(output).binwrite(body)
    end

    module_function def find_method(node, name)
      return node if node.is_a?(Prism::DefNode) && node.name == name

      node.compact_child_nodes.each do |child|
        found = find_method(child, name)
        return found if found
      end
      nil
    end

    module_function def method_names(node, names = [])
      names << node.name if node.is_a?(Prism::DefNode)
      node.compact_child_nodes.each { |child| method_names(child, names) }
      names
    end

    module_function def validate_signature!(node, source_name)
      parameters = node.parameters
      valid = node.receiver.is_a?(Prism::SelfNode) &&
        parameters.requireds.map(&:name) == [:instance] &&
        parameters.optionals.empty? && parameters.rest.nil? && parameters.keywords.empty? &&
        parameters.keyword_rest.nil? && parameters.block.nil?
      return if valid

      raise GenerationError, "#{source_name}:#{node.location.start_line}: boolean_instance? must be a singleton method taking exactly instance"
    end

    module_function def lower(node, source_name)
      case node
      when Prism::OrNode
        {op: :or, left: lower(node.left, source_name), right: lower(node.right, source_name)}
      when Prism::CallNode
        lower_call(node, source_name)
      else
        location = node&.location&.start_line || 1
        kind = node ? node.class.name.delete_prefix("Prism::") : "empty body"
        raise GenerationError, "#{source_name}:#{location}: unsupported syntax #{kind}"
      end
    end

    module_function def lower_call(node, source_name)
      receiver = node.receiver
      argument = node.arguments&.arguments
      if node.name == :equal? && [Prism::TrueNode, Prism::FalseNode].any? { |type| receiver.is_a?(type) } &&
          argument&.length == 1 && argument.first.is_a?(Prism::LocalVariableReadNode) && argument.first.name == :instance
        specification = intrinsic("object_identity")
        unless specification.fetch("ruby_forms").include?("literal.equal?(value)")
          raise GenerationError, "#{source_name}:#{node.location.start_line}: object_identity does not accept this Ruby form"
        end
        return {
          op: :intrinsic,
          name: specification.fetch("name"),
          operands: [{op: :literal, value: receiver.is_a?(Prism::TrueNode)}, {op: :argument, name: :instance}]
        }
      end

      location = node.location.start_line
      if receiver.is_a?(Prism::LocalVariableReadNode)
        raise GenerationError, "#{source_name}:#{location}: missing class guard for ambiguous receiver #{receiver.name} before #{node.name}"
      end
      if receiver.nil?
        raise GenerationError, "#{source_name}:#{location}: implicit generic dispatch #{node.name} is not allowlisted"
      end

      raise GenerationError, "#{source_name}:#{location}: unsupported call #{node.name} on unknown receiver"
    end

    module_function def emit(ir, fingerprints)
      expression = emit_expression(ir.fetch(:expression))
      metadata = fingerprints.sort.map { |key, value| " * #{key}: #{value}" }.join("\n")
      <<~C
        /* Generated by tool/native_generator.rb. Do not edit.
        #{metadata}
         */
        #include "ruby.h"

        VALUE
        schemurai_generated_boolean_instance(VALUE self, VALUE instance)
        {
            (void)self;
            return #{expression} ? Qtrue : Qfalse;
        }
      C
    end

    module_function def emit_expression(node)
      case node.fetch(:op)
      when :or
        "(#{emit_expression(node.fetch(:left))} || #{emit_expression(node.fetch(:right))})"
      when :intrinsic
        specification = intrinsic(node.fetch(:name))
        operands = node.fetch(:operands).map { |operand| emit_operand(operand) }
        specification.fetch("c_lowering").sub("$left", operands.fetch(0)).sub("$right", operands.fetch(1))
      else
        raise GenerationError, "unknown lowering operation #{node.fetch(:op)}"
      end
    end

    module_function def emit_operand(node)
      case node.fetch(:op)
      when :literal
        node.fetch(:value) ? "Qtrue" : "Qfalse"
      when :argument
        node.fetch(:name).to_s
      else
        raise GenerationError, "unknown operand operation #{node.fetch(:op)}"
      end
    end

    module_function def intrinsic(name)
      entries = load_json("native/intrinsics.json").fetch("intrinsics")
      entries.find { |entry| entry.fetch("name") == name } || raise(GenerationError, "missing intrinsic #{name}")
    end
  end
end
