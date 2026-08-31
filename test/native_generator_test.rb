# frozen_string_literal: true

require "tmpdir"
require "rspec"
require_relative "../tool/native_generator"

RSpec.describe Schemurai::NativeGenerator do
  def compile(body)
    source = <<~RUBY
      def self.boolean_instance?(instance)
        #{body}
      end
    RUBY
    described_class.compile(source, source_name: "fixture.rb")
  end

  it "validates complete, typed manifests" do
    expect(described_class.validate_manifests!).to be(true)
    source = File.read("lib/schemurai/type_slice.rb")
    expect(described_class.validate_type_slice!(source)).to be(true)
    expect(described_class.compile_type_slice(source)).to include(
      name: :valid?, result: :c_boolean,
      type_names: %w[null boolean object array number integer string],
      intrinsics: %w[object_identity exact_builtin_guard finite_float integral_float]
    )
  end

  it "audits every maintained translation source against the declared AST subset" do
    inventories = described_class.audit_translation_units!

    expect(inventories.keys).to contain_exactly(
      "bootstrap_type", "type_slice", "schema_compilation", "evaluation",
      "dialect", "format", "content", "result_construction"
    )
    expect(inventories.fetch("evaluation")).to include("exception_region", "iterator")
  end

  it "maps every maintained source ensure and rescue region to generated cleanup policy" do
    map = described_class.cleanup_region_map

    expect(described_class.validate_cleanup_region_map!).to be(true)
    expect(map.fetch("regions")).not_to be_empty
    expect(map.fetch("regions").map { |region| region.fetch("kind") }.uniq).to contain_exactly("ensure", "rescue")
    expect(map.fetch("regions")).to all(include("source", "units", "start_line", "end_line", "lowering"))
    expect(map.fetch("regions").select { |region| region.fetch("kind") == "ensure" })
      .to all(include("lowering" => "idempotent_cleanup"))
  end

  it "lowers every named root to deterministic typed syntax IR" do
    units = described_class.lower_translation_units!

    evaluation = units.fetch("evaluation")
    expect(evaluation.fetch("stage")).to eq("syntax_audited")
    expect(evaluation.fetch("roots").map { |root| root.fetch("root") }).to eq(
      ["Schemurai::Internal::Evaluator#evaluate_valid", "Schemurai::Internal::Evaluator#evaluate"]
    )
    expect(JSON.generate(units)).to eq(JSON.generate(described_class.lower_translation_units!))
  end

  it "rejects an undeclared AST form with its translation source location" do
    ir = described_class.load_json("native/lowering_ir.json")
    ir.fetch("ast_forms").fetch("control_flow").delete("OrNode")
    units = {
      "units" => [described_class.load_json("native/translation_units.json").fetch("units").first]
    }

    expect { described_class.audit_translation_units!(ir:, units:) }
      .to raise_error(
        described_class::GenerationError,
        /native\/source\/bootstrap\.rb:6: unsupported syntax OrNode in translation unit bootstrap_type/
      )
  end

  it "requires forced-exception coverage for allocating intrinsics in owned regions" do
    allocating = {
      "name" => "allocate_buffer", "allocates" => true, "invokes_ruby" => false
    }
    region = {
      "name" => "fixture", "resources" => ["buffer"], "operations" => ["allocate_buffer"],
      "cleanup" => "idempotent_ensure", "forced_exceptions" => []
    }

    expect { described_class.validate_owned_region!(region, entries: [allocating]) }
      .to raise_error(described_class::GenerationError, /lacks a forced-exception fixture for allocate_buffer/)
    region["forced_exceptions"] << "allocate_buffer"
    expect(described_class.validate_owned_region!(region, entries: [allocating])).to be(true)
  end

  it "reproduces the committed output byte for byte" do
    Dir.mktmpdir do |directory|
      output = File.join(directory, "generated_bootstrap.c")
      described_class.generate(output)

      expect(File.binread(output)).to eq(File.binread("ext/schemurai/generated_bootstrap.c"))
    end
  end

  it "initializes immutable generated lookup values once" do
    source = described_class.emit(
      described_class.compile(File.read("native/source/bootstrap.rb")),
      {},
      described_class.compile_type_slice(File.read("lib/schemurai/type_slice.rb"))
    )

    expect(source).to include('rb_str_new_static("type", 4)')
    expect(source.scan("rb_str_new_static").length).to eq(1)
    expect(source.scan('rb_intern_const("Complex")').length).to eq(1)
    expect(source).to include("schemurai_generated_id_finite", "schemurai_generated_id_to_i")
  end

  it "reproduces the committed cleanup-region map byte for byte" do
    Dir.mktmpdir do |directory|
      output = File.join(directory, "cleanup_regions.json")
      described_class.generate_cleanup_region_map(output)

      expect(File.binread(output)).to eq(File.binread("native/cleanup_regions.json"))
    end
  end

  it "lowers every supported expression to typed intrinsic IR" do
    ir = compile("true.equal?(instance) || false.equal?(instance)")

    expect(ir).to eq(
      name: :boolean_instance?,
      parameters: [:instance],
      result: :c_boolean,
      expression: {
        op: :or,
        left: {op: :intrinsic, name: "object_identity", operands: [{op: :literal, value: true}, {op: :argument, name: :instance}]},
        right: {op: :intrinsic, name: "object_identity", operands: [{op: :literal, value: false}, {op: :argument, name: :instance}]}
      }
    )
  end

  it "lowers boolean conjunctions to typed control-flow IR" do
    ir = compile("true.equal?(instance) && false.equal?(instance)")

    expect(ir.fetch(:expression)).to include(op: :and)
  end

  it "lowers ensure bodies to idempotent cleanup regions" do
    ir = compile(<<~RUBY)
      begin
        true.equal?(instance)
      ensure
        false.equal?(instance)
      end
    RUBY

    expect(ir.fetch(:expression)).to eq(
      op: :ensure_region,
      body: [
        {
          op: :protected_region,
          body: [{op: :intrinsic, name: "object_identity", operands: [{op: :literal, value: true}, {op: :argument, name: :instance}]}],
          rescue: nil
        }
      ],
      cleanup: [
        {op: :intrinsic, name: "object_identity", operands: [{op: :literal, value: false}, {op: :argument, name: :instance}]}
      ],
      cleanup_policy: :idempotent
    )
  end

  it "emits ensure, protect, and iterator calls from control regions" do
    ensure_call = described_class.emit_control_region(
      {op: :ensure_region}, body_function: "evaluate_body", cleanup_function: "evaluate_cleanup", state: "state"
    )
    protect_call = described_class.emit_control_region(
      {op: :protected_region}, body_function: "evaluate_body", state: "state"
    )
    iterator_call = described_class.emit_control_region(
      {op: :iterator_region}, body_function: "unused", callback_function: "each_callback",
      method_id: "id_each", state: "collection"
    )

    expect(ensure_call).to eq("rb_ensure(evaluate_body, state, evaluate_cleanup, state)")
    expect(protect_call).to eq("rb_protect(evaluate_body, state, &state_tag)")
    expect(iterator_call).to eq("rb_block_call(collection, id_each, 0, NULL, each_callback, Qnil)")
  end

  it "emits typed-data graph access only through manifest intrinsics" do
    expect(described_class.emit_graph_access("node_type_mask", receiver: "graph", operands: ["node"]))
      .to eq("schemurai_node_type_mask(graph, node)")
    expect { described_class.emit_graph_access("unknown", receiver: "graph", operands: []) }
      .to raise_error(described_class::GenerationError, /missing graph intrinsic unknown/)
  end

  it "rejects an unknown receiver without a class guard" do
    expect { compile("instance.empty?") }
      .to raise_error(described_class::GenerationError, /fixture\.rb:2: missing class guard for ambiguous receiver instance/)
  end

  it "rejects implicit generic dispatch" do
    expect { compile("unknown_operation(instance)") }
      .to raise_error(described_class::GenerationError, /implicit generic dispatch unknown_operation is not allowlisted/)
  end

  it "rejects unsupported syntax with a source location" do
    expect { compile("if instance\n true\n end") }
      .to raise_error(described_class::GenerationError, /fixture\.rb:2: unsupported syntax IfNode/)
  end
end
