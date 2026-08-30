# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/json_schema_validator/schema_graph"

RSpec.describe "JsonSchemaValidator::Internal::SchemaGraph" do
  def internal
    JsonSchemaValidator.const_get(:Internal)
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
      expect(JsonSchemaValidator.valid?(ref_sibling_schema, 1)).to be(false)
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
