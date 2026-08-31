# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/schemurai/schema_graph"

RSpec.describe "Schemurai::Internal::SchemaGraph" do
  def internal
    Schemurai.const_get(:Internal)
  end

  def graph_class
    internal.const_get(:SchemaGraph)
  end

  def dialect_class
    internal.const_get(:Dialect)
  end

  def draft7
    internal.const_get(:Dialects).const_get(:Draft7).const_get(:DIALECT)
  end

  describe "Draft 7 compilation" do
    subject(:graph) { graph_class.new }

    let(:root) { graph.compile(schema) }

    let(:schema) do
      {
        "type" => "object",
        "properties" => {"x/y" => {"type" => "integer"}},
        "dependencies" => {"x" => ["y"], "z" => {"required" => ["q"]}},
        "unknown" => {"type" => "string"}
      }
    end

    it "describes keyword masks and subschema locations", :aggregate_failures do
      expect(root.keyword_mask).to eq(65)
      expect(root.child("properties", "x/y").schema_path).to eq("/properties/x~1y")
      expect(root.child("dependencies", "z").schema_path).to eq("/dependencies/z")
    end
  end

  describe "schema occurrences" do
    subject(:graph) { graph_class.new }

    let(:reused) { {"type" => "integer"} }
    let(:root) { graph.compile({"allOf" => [reused, reused]}) }
    let(:first) { root.child("allOf", 0) }
    let(:second) { root.child("allOf", 1) }

    it "creates a node for each occurrence", :aggregate_failures do
      expect(first).not_to equal(second)
      expect([first.schema_path, second.schema_path]).to eq(["/allOf/0", "/allOf/1"])
    end
  end

  describe "failed compilation" do
    subject(:graph) { graph_class.new(dialect: assertion_dialect) }

    let(:assertion_dialect) do
      dialect_class.new(
        name: :format_assertion,
        uri: "https://example.test/dialect/format-assertion",
        keywords: draft7.keywords,
        ref_siblings: draft7.ref_siblings?,
        format_assertion: true
      )
    end
    let!(:existing) do
      graph.compile({
        "$id" => "https://example.test/existing",
        "definitions" => {"value" => {"type" => "integer"}}
      })
    end
    let!(:state_before) { graph_state(graph) }
    let!(:collections_before) { graph_collections(graph, existing) }
    let(:failing_schema) do
      {
        "$id" => "https://example.test/existing",
        "$dynamicRef" => "#value",
        "definitions" => {
          "added" => {"$anchor" => "added", "type" => "string"},
          "invalid" => {"format" => "unknown"}
        }
      }
    end

    def graph_state(graph)
      {
        resources: graph.resources.dup,
        resource_nodes: graph.resources.transform_values { |resource| resource.nodes.dup },
        uri_registry: graph.uri_registry.dup,
        nodes: graph.nodes.dup,
        dynamic_scope: graph.dynamic_scope?
      }
    end

    def graph_collections(graph, root)
      [graph.resources, graph.uri_registry, graph.nodes, root.resource.nodes]
    end

    def expect_same_collections(actual, expected)
      expect(actual).to match(expected.map { |collection| equal(collection) })
    end

    it "leaves the graph unchanged when a nested schema raises", :aggregate_failures do
      expect { graph.compile(failing_schema) }
        .to raise_error(Schemurai::UnsupportedFormatError, /unsupported format "unknown"/)
      expect(graph_state(graph)).to eq(state_before)
      expect_same_collections(graph_collections(graph, existing), collections_before)
      expect(graph.node_at("https://example.test/existing")).to equal(existing)
    end
  end

  describe "dynamic scope tracking" do
    it "remains enabled after a compiled schema requires it" do
      graph = graph_class.new

      graph.compile({"$dynamicRef" => "#item"})
      graph.compile(true)

      expect(graph).to be_dynamic_scope
    end
  end

  describe "$ref sibling policies" do
    let(:reference) { "#/definitions/value" }
    let(:definitions) { {"value" => {"type" => "integer"}} }
    let(:dialect_uri) { "https://example.test/dialect/ref-siblings" }
    let(:ref_sibling_dialect) do
      dialect_class.new(
        name: :ref_siblings,
        uri: dialect_uri,
        keywords: draft7.keywords,
        ref_siblings: true
      )
    end
    let(:ref_sibling_schema) do
      {
        "$schema" => dialect_uri,
        "$ref" => reference,
        "type" => "string",
        "definitions" => definitions
      }
    end

    it "uses the Draft 7 exclusive policy", :aggregate_failures do
      graph = graph_class.new
      root = graph.compile({"$ref" => reference, "definitions" => definitions})
      expect(draft7.ref_siblings?).to be(false)
      expect(root.child("definitions", "value")).to be_nil
    end

    it "uses the policy of a declared dialect" do
      dialect_class.register(ref_sibling_dialect)
      expect(Schemurai.valid?(ref_sibling_schema, 1)).to be(false)
    end
  end

  describe "local references" do
    subject(:graph) { graph_class.new }

    let(:schema) do
      {
        "$id" => "https://example.test/root",
        "definitions" => {"a/b" => {"$id" => "named", "type" => "integer"}}
      }
    end
    let(:root) { graph.compile(schema) }
    let(:escaped) { graph.resolve(root, "#/definitions/a~1b") }

    it "resolves escaped pointers and identifiers", :aggregate_failures do
      expect(escaped.schema["type"]).to eq("integer")
      expect(graph.resolve(root, "named")).to equal(escaped)
    end
  end

  describe "nested resources" do
    subject(:graph) { graph_class.new }

    let(:schema) do
      {
        "$id" => "https://example.test/root",
        "$dynamicAnchor" => "item",
        "definitions" => {
          "nested" => {
            "$id" => "folder/",
            "$dynamicAnchor" => "item",
            "definitions" => {"value" => {"$ref" => "target"}}
          }
        }
      }
    end

    let(:root) { graph.compile(schema) }

    it "preserves the resource base when reached through a parent pointer" do
      target = graph.resolve(root, "#/definitions/nested/definitions/value")
      expect(target.base_uri).to eq("https://example.test/folder/")
    end

    it "keeps same-named dynamic anchors separate by resource", :aggregate_failures do
      nested = root.child("definitions", "nested")
      expect(graph.dynamic_anchor(root.resource, "item")).to equal(root)
      expect(graph.dynamic_anchor(nested.resource, "item")).to equal(nested)
    end
  end

  describe "external resources" do
    context "with one external schema" do
      let(:external) { {"definitions" => {"value" => {"type" => "string"}}} }
      let(:graph) do
        graph_class.new(schemas: {"https://example.test/external" => external})
      end
      let(:root) { graph.compile({"$ref" => "https://example.test/external#/definitions/value"}) }

      it "indexes it lazily with its retrieval URI", :aggregate_failures do
        target = graph.resolve(root, root.schema["$ref"])
        expect(target.schema).to eq("type" => "string")
        expect(target.schema_path).to eq("/definitions/value")
      end
    end

    context "with two external schemas" do
      let(:graph) do
        graph_class.new(schemas: {
          "https://example.test/one" => {"definitions" => {"value" => {"const" => 1}}},
          "https://example.test/two" => {"definitions" => {"value" => {"const" => 2}}}
        })
      end
      let(:root) { graph.compile(true) }
      let(:one) { graph.resolve(root, "https://example.test/one#/definitions/value") }
      let(:two) { graph.resolve(root, "https://example.test/two#/definitions/value") }

      it "keeps identical pointers in separate resources" do
        expect([one.schema["const"], two.schema["const"]]).to eq([1, 2])
      end
    end

    context "when the graph compiles multiple root schemas" do
      let(:reference) { "https://example.test/shared" }
      let(:graph) do
        graph_class.new(schemas: {reference => {"type" => "integer"}})
      end

      it "reuses a root for the same schema identity and effective base URI" do
        schema = {"type" => "integer"}

        first = graph.compile(schema)
        second = graph.compile(schema, base_uri: "")

        expect(second).to equal(first)
      end

      it "keeps structurally equal schema objects separate" do
        schema = {"type" => "integer"}

        first = graph.compile(schema)
        second = graph.compile(schema.dup)

        expect(second).not_to equal(first)
      end

      it "keeps different base URIs separate" do
        schema = {"type" => "integer"}

        first = graph.compile(schema, base_uri: "urn:first")
        second = graph.compile(schema, base_uri: "urn:second")

        expect(second).not_to equal(first)
      end

      it "reuses the compiled external resource" do
        first_root = graph.compile({"$ref" => reference})
        first_target = graph.resolve(first_root, reference)
        second_root = graph.compile({"$ref" => reference})

        expect(graph.resolve(second_root, reference)).to equal(first_target)
      end

      it "keeps anonymous documents and their local references separate" do
        first = graph.compile({"$ref" => "#/$defs/value", "$defs" => {"value" => {"const" => 1}}})
        second = graph.compile({"$ref" => "#/$defs/value", "$defs" => {"value" => {"const" => 2}}})

        constants = [first, second].map { |root| graph.resolve(root, root.schema["$ref"]).schema["const"] }
        expect(constants).to eq([1, 2])
      end

      it "indexes lazily materialized nodes in separate anonymous documents" do
        first = graph.compile({"$ref" => "#/extension", "extension" => {"const" => 1}})
        second = graph.compile({"$ref" => "#/extension", "extension" => {"const" => 2}})

        constants = [first, second].map { |root| graph.resolve(root, root.schema["$ref"]).schema["const"] }
        expect(constants).to eq([1, 2])
      end
    end
  end

  describe "unknown keywords" do
    subject(:graph) { graph_class.new }

    let(:root) { graph.compile({"extension" => {"type" => "integer"}}) }
    let(:target) { graph.resolve(root, "#/extension") }

    it "materializes a referenced target on demand", :aggregate_failures do
      expect(root.child("extension")).to be_nil
      expect(target.schema).to eq("type" => "integer")
      expect(target.schema_path).to eq("/extension")
    end
  end
end
