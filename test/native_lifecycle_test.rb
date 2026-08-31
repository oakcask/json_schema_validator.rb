# frozen_string_literal: true

require "timeout"
require "rspec"
require "schemurai"
require "schemurai/native"

RSpec.describe "native concurrency and lifecycle safety" do
  def native_validator(validator)
    validator.instance_variable_get(:@evaluator)
  end

  def native_graph(validator)
    native_validator(validator).instance_variable_get(:@graph)
  end

  it "audits the Ractor-safe declaration, globals, and every retained Ruby value" do # rubocop:disable RSpec/ExampleLength
    source = File.read("ext/schemurai/runtime.c")
    structs = source.scan(/typedef struct \{(.*?)\} (schemurai_\w+_t);/m).to_h { |body, name| [name, body] }
    node_fields = structs.fetch("schemurai_node_t").scan(/^\s+VALUE (\w+);$/).flatten
    graph_fields = structs.fetch("schemurai_graph_t").scan(/^\s+VALUE (\w+);$/).flatten
    global_values = source.scan(/^static VALUE (\w+);$/).flatten
    global_ids = source.scan(/^static ID (\w+);$/).flatten

    expect(source).to include("rb_ext_ractor_safe(true)")
    expect(global_values).to be_empty
    expect(global_ids).not_to be_empty
    global_ids.each do |identifier|
      expect(source.scan(/\b#{Regexp.escape(identifier)}\s*=/).length).to eq(1)
    end

    node_fields.each do |field|
      expect(source).to include("rb_gc_mark_movable(node->#{field})")
      expect(source).to include("node->#{field} = rb_gc_location(node->#{field})")
      expect(source).to include("rb_ractor_make_shareable(node->#{field})")
    end
    graph_fields.each do |field|
      expect(source).to include("rb_gc_mark_movable(graph->#{field})")
      expect(source).to include("graph->#{field} = rb_gc_location(graph->#{field})")
      expect(source).to include("rb_ractor_make_shareable(graph->#{field})")
    end
  end

  it "keeps the complete retained graph and validator shareable after compaction" do
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://example.test/lifecycle",
      "$dynamicAnchor" => "root",
      "format" => "date",
      "properties" => {"value" => {"type" => "integer"}},
      "$defs" => {"fallback" => {"type" => "string"}}
    }
    validator = Schemurai.compile(schema, format: true, backend: :native)
    graph = native_graph(validator)

    GC.stress = true
    GC.start
    GC.compact

    expect(graph).to be_frozen
    expect(graph.shareable_state?).to be(true)
    expect(Ractor.shareable?(graph)).to be(true)
    expect(Ractor.shareable?(validator)).to be(true)
    graph.node_count.times do |index|
      expect(graph.node_metadata(index).values).to all(satisfy { |value| Ractor.shareable?(value) })
    end
  ensure
    GC.stress = false
  end

  it "stress-tests independent validators across threads and Ractors" do # rubocop:disable RSpec/ExampleLength
    schema = {
      "type" => "object",
      "required" => ["value"],
      "properties" => {"value" => {"type" => "integer", "minimum" => 1}}
    }
    validators = 8.times.map { Schemurai.compile(schema, backend: :native) }

    thread_results = validators.map.with_index do |validator, index|
      Thread.new do
        200.times.all? do
          valid = validator.valid?("value" => index + 1)
          errors = validator.validate("value" => 0).errors.map { |error| [error.keyword, error.instance_path] }
          valid && errors == [["minimum", "/value"]]
        end
      end
    end.map(&:value)
    expect(thread_results).to all(be(true))

    ractors = validators.first(2).map do |validator|
      Ractor.new(validator) do |shared|
        100.times.map do
          [shared.valid?("value" => 2), shared.validate("value" => 0).errors.map(&:instance_path)]
        end.uniq
      end
    end
    results = ractors.map { |ractor| ractor.respond_to?(:value) ? ractor.value : ractor.take }
    expect(results).to eq(Array.new(2) { [[true, ["/value"]]] })
  end

  it "observes interrupts in the native repeated-validation loop and remains reusable", :asynchronous_interrupt do
    validator = Schemurai.compile({"type" => "integer"}, backend: :native)
    implementation = native_validator(validator)
    graph = native_graph(validator)
    started = Queue.new
    worker = Thread.new do
      started << true
      implementation.__validate_repeated__(1, 1_000_000_000)
    end
    worker.report_on_exception = false
    started.pop
    worker.raise(Interrupt)

    expect(graph.method(:__validate_repeated__).source_location).to be_nil
    expect { Timeout.timeout(5) { worker.value } }.to raise_error(Interrupt)
    expect(validator.valid?(1)).to be(true)
  ensure
    worker&.kill
  end

  it "does not retain stale errors, paths, or per-call state after failures" do
    validator = Schemurai.compile(
      {"properties" => {"items" => {"items" => {"type" => "integer"}}}},
      backend: :native
    )

    100.times do
      invalid = validator.validate("items" => [1, "bad"])
      valid = validator.validate("items" => [1, 2])
      expect(invalid.errors.map { |error| [error.keyword, error.instance_path] })
        .to eq([["type", "/items/1"]])
      expect(valid.errors).to be_empty
    end

    exceptional = Class.new(Numeric) do
      def finite? = raise("forced native compatibility failure")
    end.new
    integer_validator = Schemurai.compile({"type" => "integer"}, backend: :native)
    expect { integer_validator.valid?(exceptional) }
      .to raise_error(RuntimeError, "forced native compatibility failure")
    expect(integer_validator.validate(1).errors).to be_empty
  end

  it "releases partially initialized records after a compilation exception" do
    record = {
      schema: Object.new,
      dialect: :draft7,
      dialect_uri: "http://json-schema.org/draft-07/schema",
      ref_siblings: false,
      format_assertion: false,
      supports_min_contains: false,
      base_uri: "",
      schema_path: "",
      resource_path: "",
      resource_root: 0,
      keyword_mask: 0,
      format: nil,
      children: [],
      references: []
    }
    snapshot = {root: 0, nodes: [record], uri_registry: {}, dynamic_anchors: {}, dynamic_scope: false}

    expect { Schemurai::Native::Graph.new(snapshot) }.to raise_error(TypeError)
    GC.start
    GC.compact
    expect(Schemurai.valid?({"type" => "integer"}, 1, backend: :native)).to be(true)
  end
end
