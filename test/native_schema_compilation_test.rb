# frozen_string_literal: true

require "rspec"
require "schemurai"
require "schemurai/native"

RSpec.describe "native schema compilation and ownership" do
  def native_graph(validator)
    validator.instance_variable_get(:@evaluator).instance_variable_get(:@graph)
  end

  it "owns every compiled node and its dialect, path, keyword, and child metadata" do
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://example.test/root",
      "type" => "object",
      "properties" => {"x/y" => {"type" => "integer"}},
      "$defs" => {"fallback" => {"type" => "string"}}
    }
    graph = native_graph(Schemurai.compile(schema, backend: :native))
    root = graph.root_index
    property = graph.child(root, "properties", "x/y")

    expect(graph.node_count).to eq(3)
    expect(graph.lookup("https://example.test/root")).to eq(root)
    expect(graph.node_metadata(root)).to include(
      dialect: :draft2020_12,
      base_uri: "https://example.test/root",
      schema_path: "",
      resource_path: "",
      keyword_mask: 65
    )
    expect(graph.node_metadata(property)).to include(
      schema: {"type" => "integer"},
      schema_path: "/properties/x~1y",
      resource_path: "/properties/x~1y",
      keyword_mask: 1
    )
  end

  it "pre-resolves local and external references to immutable node indexes" do
    external_uri = "https://example.test/external"
    validator = Schemurai.compile(
      {"$ref" => "#{external_uri}#/$defs/value"},
      schemas: {external_uri => {"$defs" => {"value" => {"type" => "integer"}}}},
      backend: :native
    )
    graph = native_graph(validator)
    target = graph.resolve(graph.root_index, "#{external_uri}#/$defs/value")

    expect(target).to be_a(Integer)
    expect(graph.node_metadata(target)).to include(
      schema: {"type" => "integer"},
      schema_path: "/$defs/value",
      keyword_mask: 1
    )
  end

  it "retains resource-scoped dynamic anchors and format metadata" do
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$id" => "https://example.test/root",
      "$dynamicAnchor" => "item",
      "format" => "date",
      "$defs" => {
        "nested" => {"$id" => "nested", "$dynamicAnchor" => "item", "type" => "string"}
      }
    }
    graph = native_graph(Schemurai.compile(schema, backend: :native))
    root = graph.root_index
    nested = graph.child(root, "$defs", "nested")

    expect(graph.dynamic_anchor(root, "item")).to eq(root)
    expect(graph.dynamic_anchor(nested, "item")).to eq(nested)
    expect(graph.node_metadata(root)).to include(format: "date")
  end

  it "supports shareable registry lookup and independent native validators" do
    uri = "https://example.test/registered"
    registry = Schemurai::SchemaRegistry.new(
      schemas: {uri => {"type" => "integer"}},
      backend: :native
    )
    registry.compile(true)
    registry.make_shareable
    first = registry.validator_for(uri)
    second = registry.validator_for(uri)

    expect([first.backend, first.valid?(1), first.valid?(1.5)]).to eq([:native, true, false])
    expect(second).not_to equal(first)
    expect(Ractor.shareable?(first)).to be(true)
    expect(Ractor.shareable?(second)).to be(true)
  end

  it "leaves registry state usable after an atomic compilation failure" do
    registry = Schemurai::SchemaRegistry.new(backend: :native)
    existing = registry.compile({"$id" => "https://example.test/existing", "type" => "integer"})

    expect do
      registry.compile({"$schema" => "urn:missing", "$ref" => "urn:unresolvable"})
    end.to raise_error(Schemurai::ResolutionError, /unresolvable reference/)
    expect(existing.valid?(3)).to be(true)
  end

  it "marks and relocates all retained node fields during stress and compaction" do
    schema = {"allOf" => 40.times.map { |index| {"$id" => "urn:node:#{index}", "type" => "integer"} }}
    graph = native_graph(Schemurai.compile(schema, backend: :native))

    GC.stress = true
    GC.start
    GC.compact
    expect(graph.node_count).to eq(41)
    expect(graph.node_metadata(graph.child(graph.root_index, "allOf", 39))).to include(
      base_uri: "urn:node:39",
      schema_path: "/allOf/39"
    )
    expect(graph).to be_frozen
    expect(graph.shareable_state?).to be(true)
    expect(Ractor.shareable?(graph)).to be(true)
  ensure
    GC.stress = false
  end
  it "survives GC while a multi-node native graph is being initialized" do
    schema = {
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$defs" => 20.times.to_h { |index| [index.to_s, {"type" => "integer"}] },
      "type" => "integer"
    }

    GC.stress = true
    graph = native_graph(Schemurai.compile(schema, backend: :native))
    expect(graph.node_count).to eq(21)
    expect(graph.node_metadata(graph.child(graph.root_index, "$defs", "19")))
      .to include(schema_path: "/$defs/19")
  ensure
    GC.stress = false
  end

  it "releases partially initialized native records after a generated compiler exception" do
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
    expect(Schemurai.valid?({"type" => "integer"}, 1, backend: :native)).to be(true)
  end
end
