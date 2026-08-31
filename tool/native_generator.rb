# frozen_string_literal: true

require "digest"
require "json"
require "prism"

module Schemurai
  module NativeGenerator
    VERSION = 2

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
      ast_forms = ir.fetch("ast_forms")
      duplicate_forms = ast_forms.values.flatten.tally.select { |_name, count| count > 1 }.keys
      raise GenerationError, "AST forms must have one lowering category: #{duplicate_forms.first}" unless duplicate_forms.empty?

      units.fetch("units").each do |unit|
        unless %w[emitted syntax_audited].include?(unit.fetch("stage"))
          raise GenerationError, "unknown translation stage #{unit.fetch("stage")} in #{unit.fetch("name")}"
        end
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

      audit_translation_units!(ir:, units:)
      validate_cleanup_region_map!(units:)

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

      intrinsics.fetch("owned_regions").each do |region|
        validate_owned_region!(region, entries:)
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

    module_function def cleanup_region_map(units: load_json("native/translation_units.json"))
      sources = units.fetch("units").group_by { |unit| unit.fetch("source") }
      regions = sources.sort.flat_map do |source_name, source_units|
        parsed = Prism.parse(root.join(source_name).read)
        unless parsed.success?
          failure = parsed.errors.first
          raise GenerationError, "#{source_name}:#{failure.location.start_line}: #{failure.message}"
        end

        exception_regions(parsed.value).map do |node|
          {
            "source" => source_name,
            "units" => source_units.map { |unit| unit.fetch("name") }.sort,
            "kind" => node.is_a?(Prism::EnsureNode) ? "ensure" : "rescue",
            "start_line" => node.location.start_line,
            "end_line" => node.location.end_line,
            "lowering" => node.is_a?(Prism::EnsureNode) ? "idempotent_cleanup" : "protected_region"
          }
        end
      end

      {"version" => 1, "regions" => regions.sort_by { |region| [region.fetch("source"), region.fetch("start_line"), region.fetch("kind")] }}
    end

    module_function def exception_regions(node, result = [])
      result << node if node.is_a?(Prism::EnsureNode) || node.is_a?(Prism::RescueNode)
      node.compact_child_nodes.each { |child| exception_regions(child, result) }
      result
    end

    module_function def validate_cleanup_region_map!(units: load_json("native/translation_units.json"))
      committed = load_json("native/cleanup_regions.json")
      expected = cleanup_region_map(units:)
      return true if committed == expected

      raise GenerationError, "native/cleanup_regions.json does not match every maintained source ensure/rescue region"
    end

    module_function def generate_cleanup_region_map(output = "native/cleanup_regions.json")
      Pathname(output).binwrite("#{JSON.pretty_generate(cleanup_region_map)}\n")
    end

    module_function def validate_owned_region!(region, entries: nil)
      entries ||= begin
        manifest = load_json("native/intrinsics.json")
        manifest.fetch("intrinsics") + manifest.fetch("graph_intrinsics")
      end
      required = %w[name resources operations cleanup forced_exceptions]
      missing = required.reject { |field| region.key?(field) }
      raise GenerationError, "owned region lacks #{missing.join(", ")}" unless missing.empty?
      raise GenerationError, "owned region #{region.fetch("name")} has no resources" if region.fetch("resources").empty?
      unless region.fetch("cleanup") == "idempotent_ensure"
        raise GenerationError, "owned region #{region.fetch("name")} must use idempotent ensure cleanup"
      end

      by_name = entries.to_h { |entry| [entry.fetch("name"), entry] }
      region.fetch("operations").each do |name|
        specification = by_name[name]
        raise GenerationError, "unknown intrinsic #{name} in owned region #{region.fetch("name")}" unless specification
        next unless specification.fetch("allocates") || specification.fetch("invokes_ruby")
        next if region.fetch("forced_exceptions").include?(name)

        raise GenerationError, "owned region #{region.fetch("name")} lacks a forced-exception fixture for #{name}"
      end
      true
    end

    module_function def audit_translation_units!(ir: load_json("native/lowering_ir.json"), units: load_json("native/translation_units.json"))
      inventories = {}

      units.fetch("units").each do |unit|
        source_name = unit.fetch("source")
        source = root.join(source_name)
        parsed = Prism.parse(source.read)
        unless parsed.success?
          failure = parsed.errors.first
          raise GenerationError, "#{source_name}:#{failure.location.start_line}: #{failure.message}"
        end

        inventory = Hash.new(0)
        lower_syntax_node(parsed.value, source_name:, unit_name: unit.fetch("name"), ir:, inventory:)
        inventories[unit.fetch("name")] = inventory.sort.to_h
      end

      inventories
    end

    module_function def lower_translation_units!(ir: load_json("native/lowering_ir.json"), units: load_json("native/translation_units.json"))
      units.fetch("units").to_h do |unit|
        source_name = unit.fetch("source")
        parsed = Prism.parse(root.join(source_name).read)
        unless parsed.success?
          failure = parsed.errors.first
          raise GenerationError, "#{source_name}:#{failure.location.start_line}: #{failure.message}"
        end

        roots = unit.fetch("roots").map do |entry|
          method = find_method(parsed.value, entry.fetch("method").to_sym)
          unless method
            raise GenerationError, "#{source_name}:1: missing translation root #{entry.fetch("root")}"
          end
          {
            "root" => entry.fetch("root"),
            "entry" => entry.fetch("entry"),
            "result" => entry.fetch("result"),
            "body" => lower_syntax_node(
              method.body,
              source_name:,
              unit_name: unit.fetch("name"),
              ir:
            )
          }
        end
        [unit.fetch("name"), {"stage" => unit.fetch("stage"), "roots" => roots}]
      end
    end

    module_function def lower_syntax_node(node, source_name:, unit_name:, ir:, inventory: nil)
      return nil unless node

      categories = ir.fetch("ast_forms").each_with_object({}) do |(category, names), result|
        names.each { |name| result[name] = category }
      end
      name = node.class.name.delete_prefix("Prism::")
      category = categories[name]
      unless category
        raise GenerationError, "#{source_name}:#{node.location.start_line}: unsupported syntax #{name} in translation unit #{unit_name}"
      end
      inventory[category] += 1 if inventory
      {
        "form" => name,
        "category" => category,
        "ir_type" => syntax_ir_type(category),
        "line" => node.location.start_line,
        "children" => node.compact_child_nodes.map do |child|
          lower_syntax_node(child, source_name:, unit_name:, ir:, inventory:)
        end
      }
    end

    module_function def syntax_ir_type(category)
      case category
      when "control_flow", "iterator", "exception_region", "structure"
        "control_flow_region"
      else
        "ruby_value"
      end
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
      type_source_path = root.join("lib/schemurai/type_slice.rb")
      ir = compile(source_path.read, source_name: "native/source/bootstrap.rb")
      type_ir = compile_type_slice(type_source_path.read)
      translation_units = load_json("native/translation_units.json")
      fingerprints = {
        "generator" => Digest::SHA256.file(__FILE__).hexdigest,
        "source" => Digest::SHA256.file(source_path).hexdigest,
        "type_slice_source" => Digest::SHA256.file(type_source_path).hexdigest,
        "intrinsics" => Digest::SHA256.file(root.join("native/intrinsics.json")).hexdigest,
        "lowering_ir" => Digest::SHA256.file(root.join("native/lowering_ir.json")).hexdigest,
        "translation_units" => Digest::SHA256.file(root.join("native/translation_units.json")).hexdigest,
        "cleanup_regions" => Digest::SHA256.file(root.join("native/cleanup_regions.json")).hexdigest,
        "prism" => Prism::VERSION,
        "generator_version" => VERSION.to_s
      }
      translation_units.fetch("units").map { |unit| unit.fetch("source") }.uniq.sort.each do |source|
        fingerprints["translation_source:#{source}"] = Digest::SHA256.file(root.join(source)).hexdigest
      end
      lower_translation_units!(units: translation_units).sort.each do |name, lowered|
        fingerprints["translation_ir:#{name}"] = Digest::SHA256.hexdigest(JSON.generate(lowered))
      end
      body = emit(ir, fingerprints, type_ir)
      Pathname(output).binwrite(body)
    end

    module_function def validate_type_slice!(source)
      compile_type_slice(source)
      true
    end

    module_function def compile_type_slice(source)
      result = Prism.parse(source)
      raise GenerationError, "invalid type slice translation source" unless result.success?

      methods = %i[valid? type? number?].to_h { |name| [name, find_method(result.value, name)] }
      missing = methods.find { |_name, node| node.nil? }
      raise GenerationError, "missing type slice translation root #{missing.first}" if missing

      expected_parameters = {valid?: %i[type value], type?: %i[value type], number?: [:value]}
      methods.each do |name, node|
        actual = node.parameters.requireds.map(&:name)
        unless actual == expected_parameters.fetch(name)
          raise GenerationError, "invalid parameters for type slice translation root #{name}"
        end
      end

      case_node = methods.fetch(:type?).body&.body&.first
      unless case_node.is_a?(Prism::CaseNode)
        raise GenerationError, "type slice translation root type? must contain a case expression"
      end
      names = case_node.conditions.flat_map(&:conditions).map do |condition|
        unless condition.is_a?(Prism::StringNode)
          raise GenerationError, "type slice case conditions must be string literals"
        end
        condition.unescaped
      end
      expected_names = %w[null boolean object array number integer string]
      raise GenerationError, "type slice cases changed without a lowering" unless names == expected_names

      intrinsic_names = load_json("native/intrinsics.json").fetch("intrinsics").map { |entry| entry.fetch("name") }
      required_intrinsics = %w[object_identity exact_builtin_guard finite_float integral_float]
      missing_intrinsic = required_intrinsics.find { |name| !intrinsic_names.include?(name) }
      raise GenerationError, "missing type slice intrinsic #{missing_intrinsic}" if missing_intrinsic

      {name: :valid?, parameters: %i[type value], result: :c_boolean, type_names: names,
       intrinsics: required_intrinsics}
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
      when Prism::AndNode
        {op: :and, left: lower(node.left, source_name), right: lower(node.right, source_name)}
      when Prism::BeginNode
        lower_begin(node, source_name)
      when Prism::EnsureNode
        {
          op: :ensure_region,
          body: [],
          cleanup: lower_statements(node.statements, source_name),
          cleanup_policy: :idempotent
        }
      when Prism::BlockNode
        {
          op: :iterator_region,
          call: lower(node.call, source_name),
          parameters: node.parameters&.parameters&.requireds&.map(&:name) || [],
          body: lower_statements(node.body, source_name)
        }
      when Prism::CallNode
        lower_call(node, source_name)
      else
        location = node&.location&.start_line || 1
        kind = node ? node.class.name.delete_prefix("Prism::") : "empty body"
        raise GenerationError, "#{source_name}:#{location}: unsupported syntax #{kind}"
      end
    end

    module_function def lower_begin(node, source_name)
      body = lower_statements(node.statements, source_name)
      return {op: :sequence, expressions: body} unless node.rescue_clause || node.ensure_clause

      protected_region = {op: :protected_region, body:, rescue: nil}
      if node.rescue_clause
        protected_region[:rescue] = lower_statements(node.rescue_clause.statements, source_name)
      end
      return protected_region unless node.ensure_clause

      {
        op: :ensure_region,
        body: [protected_region],
        cleanup: lower_statements(node.ensure_clause.statements, source_name),
        cleanup_policy: :idempotent
      }
    end

    module_function def lower_statements(node, source_name)
      return [] unless node

      statements = node.is_a?(Prism::StatementsNode) ? node.body : [node]
      statements.map { |statement| lower(statement, source_name) }
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

    module_function def emit(ir, fingerprints, type_ir)
      expression = emit_expression(ir.fetch(:expression))
      type_bits = {
        "null" => "SCHEMURAI_TYPE_NULL", "boolean" => "SCHEMURAI_TYPE_BOOLEAN",
        "object" => "SCHEMURAI_TYPE_OBJECT", "array" => "SCHEMURAI_TYPE_ARRAY",
        "number" => "SCHEMURAI_TYPE_NUMBER", "integer" => "SCHEMURAI_TYPE_INTEGER",
        "string" => "SCHEMURAI_TYPE_STRING"
      }
      type_name_masks = type_ir.fetch(:type_names).map do |name|
        %(    if (length == #{name.length} && memcmp(bytes, "#{name}", #{name.length}) == 0) return #{type_bits.fetch(name)};)
      end.join("\n")
      metadata = fingerprints.sort.map { |key, value| " * #{key}: #{value}" }.join("\n")
      compatibility_calls = %w[
        type_integer_out_of_domain_finite
        type_integer_out_of_domain_to_i
        type_integer_out_of_domain_equality
      ].to_h { |site| [site, generic_call(site)] }
      <<~C
        /* Generated by tool/native_generator.rb. Do not edit.
        #{metadata}
         */
        #include "ruby.h"
        #include "ruby/thread.h"
        #include <math.h>
        #include <string.h>

        #define SCHEMURAI_TYPE_NULL (1UL << 0)
        #define SCHEMURAI_TYPE_BOOLEAN (1UL << 1)
        #define SCHEMURAI_TYPE_OBJECT (1UL << 2)
        #define SCHEMURAI_TYPE_ARRAY (1UL << 3)
        #define SCHEMURAI_TYPE_NUMBER (1UL << 4)
        #define SCHEMURAI_TYPE_INTEGER (1UL << 5)
        #define SCHEMURAI_TYPE_STRING (1UL << 6)
        #define SCHEMURAI_TYPE_ANY (1UL << 7)

        VALUE
        schemurai_generated_boolean_instance(VALUE self, VALUE instance)
        {
            (void)self;
            return #{expression} ? Qtrue : Qfalse;
        }

        static unsigned long
        schemurai_generated_type_name_mask(VALUE name)
        {
            const char *bytes;
            long length;

            if (!RB_TYPE_P(name, T_STRING)) return 0;
            bytes = RSTRING_PTR(name);
            length = RSTRING_LEN(name);
        #{type_name_masks}
            return 0;
        }

        unsigned long
        schemurai_generated_compile_type(VALUE schema)
        {
            VALUE type;
            unsigned long mask = 0;
            long index;

            if (schema == Qtrue) return SCHEMURAI_TYPE_ANY;
            if (schema == Qfalse) return 0;
            Check_Type(schema, T_HASH);
            type = rb_hash_lookup2(schema, rb_str_new_cstr("type"), Qundef);
            if (type == Qundef) return SCHEMURAI_TYPE_ANY;
            if (!RB_TYPE_P(type, T_ARRAY)) return schemurai_generated_type_name_mask(type);
            for (index = 0; index < RARRAY_LEN(type); index++) {
                if ((((unsigned long)index) & 0x3ffUL) == 0) {
                    rb_thread_schedule();
                    rb_thread_check_ints();
                }
                mask |= schemurai_generated_type_name_mask(RARRAY_AREF(type, index));
            }
            return mask;
        }

        static int
        schemurai_generated_number_p(VALUE value)
        {
            VALUE complex = rb_const_get(rb_cObject, rb_intern("Complex"));
            return rb_obj_is_kind_of(value, rb_cNumeric) && !rb_obj_is_kind_of(value, complex);
        }

        static int
        schemurai_generated_integer_p(VALUE value)
        {
            VALUE converted;

            if (RB_INTEGER_TYPE_P(value)) return 1;
            if (RB_TYPE_P(value, T_FLOAT)) {
                double integral;
                return isfinite(RFLOAT_VALUE(value)) && modf(RFLOAT_VALUE(value), &integral) == 0.0;
            }
            if (!schemurai_generated_number_p(value)) return 0;

            /* #{compatibility_calls.fetch("type_integer_out_of_domain_finite").fetch("classification")}: type_integer_out_of_domain_finite */
            if (!RTEST(rb_funcall(value, rb_intern("#{compatibility_calls.fetch("type_integer_out_of_domain_finite").fetch("method")}"), 0))) return 0;
            /* #{compatibility_calls.fetch("type_integer_out_of_domain_to_i").fetch("classification")}: type_integer_out_of_domain_to_i */
            converted = rb_funcall(value, rb_intern("#{compatibility_calls.fetch("type_integer_out_of_domain_to_i").fetch("method")}"), 0);
            /* #{compatibility_calls.fetch("type_integer_out_of_domain_equality").fetch("classification")}: type_integer_out_of_domain_equality */
            return RTEST(rb_equal(converted, value));
        }

        int
        schemurai_generated_valid_type(unsigned long mask, VALUE value)
        {
            if (mask & SCHEMURAI_TYPE_ANY) return 1;
            if (NIL_P(value)) return (mask & SCHEMURAI_TYPE_NULL) != 0;
            if (value == Qtrue || value == Qfalse) return (mask & SCHEMURAI_TYPE_BOOLEAN) != 0;
            if (RB_TYPE_P(value, T_HASH)) return (mask & SCHEMURAI_TYPE_OBJECT) != 0;
            if (RB_TYPE_P(value, T_ARRAY)) return (mask & SCHEMURAI_TYPE_ARRAY) != 0;
            if (RB_TYPE_P(value, T_STRING)) return (mask & SCHEMURAI_TYPE_STRING) != 0;
            if (RB_INTEGER_TYPE_P(value)) return (mask & (SCHEMURAI_TYPE_NUMBER | SCHEMURAI_TYPE_INTEGER)) != 0;
            if (RB_TYPE_P(value, T_FLOAT)) {
                if (mask & SCHEMURAI_TYPE_NUMBER) return 1;
                return (mask & SCHEMURAI_TYPE_INTEGER) != 0 && schemurai_generated_integer_p(value);
            }

            /* Subclasses and other Numeric implementations are outside the supported hot path. */
            if ((mask & SCHEMURAI_TYPE_OBJECT) && rb_obj_is_kind_of(value, rb_cHash)) return 1;
            if ((mask & SCHEMURAI_TYPE_ARRAY) && rb_obj_is_kind_of(value, rb_cArray)) return 1;
            if ((mask & SCHEMURAI_TYPE_STRING) && rb_obj_is_kind_of(value, rb_cString)) return 1;
            if ((mask & SCHEMURAI_TYPE_NUMBER) && schemurai_generated_number_p(value)) return 1;
            return (mask & SCHEMURAI_TYPE_INTEGER) != 0 && schemurai_generated_integer_p(value);
        }
      C
    end

    module_function def emit_expression(node)
      case node.fetch(:op)
      when :or
        "(#{emit_expression(node.fetch(:left))} || #{emit_expression(node.fetch(:right))})"
      when :and
        "(#{emit_expression(node.fetch(:left))} && #{emit_expression(node.fetch(:right))})"
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

    module_function def emit_control_region(node, body_function:, state:, cleanup_function: nil, callback_function: nil, method_id: nil)
      identifiers = [body_function, cleanup_function, callback_function].compact
      unless identifiers.all? { |identifier| /\A[a-zA-Z_][a-zA-Z0-9_]*\z/.match?(identifier) }
        raise GenerationError, "control-region callbacks must be C identifiers"
      end

      case node.fetch(:op)
      when :ensure_region
        raise GenerationError, "ensure region requires cleanup callback" unless cleanup_function

        "rb_ensure(#{body_function}, #{state}, #{cleanup_function}, #{state})"
      when :protected_region
        "rb_protect(#{body_function}, #{state}, &state_tag)"
      when :iterator_region
        raise GenerationError, "iterator region requires callback and method ID" unless callback_function && method_id

        "rb_block_call(#{state}, #{method_id}, 0, NULL, #{callback_function}, Qnil)"
      else
        raise GenerationError, "unknown control region #{node.fetch(:op)}"
      end
    end

    module_function def emit_graph_access(name, receiver:, operands:)
      manifest = load_json("native/intrinsics.json")
      specification = manifest.fetch("graph_intrinsics").find { |entry| entry.fetch("name") == name }
      raise GenerationError, "missing graph intrinsic #{name}" unless specification
      unless operands.length == specification.fetch("operands").length
        raise GenerationError, "graph intrinsic #{name} expects #{specification.fetch("operands").length} operands"
      end

      arguments = [receiver, *operands].join(", ")
      "#{specification.fetch("c_lowering")}(#{arguments})"
    end

    module_function def intrinsic(name)
      entries = load_json("native/intrinsics.json").fetch("intrinsics")
      entries.find { |entry| entry.fetch("name") == name } || raise(GenerationError, "missing intrinsic #{name}")
    end

    module_function def generic_call(site)
      calls = load_json("native/intrinsics.json").fetch("generic_calls")
      calls.find { |call| call.fetch("site") == site } || raise(GenerationError, "missing generic call site #{site}")
    end
  end
end
