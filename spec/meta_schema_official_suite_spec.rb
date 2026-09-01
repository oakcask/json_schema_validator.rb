# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../oracle/lib/case_catalog"

dialect_uris = {
  "draft7" => "http://json-schema.org/draft-07/schema",
  "draft2019-09" => "https://json-schema.org/draft/2019-09/schema",
  "draft2020-12" => "https://json-schema.org/draft/2020-12/schema"
}.freeze

RSpec.describe "official suite schema meta-schema validation" do
  define_method(:schema_for_dialect) do |schema, dialect|
    return schema unless schema.is_a?(Hash) && !schema.key?("$schema")

    schema.merge("$schema" => dialect_uris.fetch(dialect))
  end

  dialect_uris.each_key do |dialect|
    it "validates every unique #{dialect} schema against its meta-schema" do # rubocop:disable RSpec/ExampleLength
      catalog = SchemuraiOracle::CaseCatalog.new
      records = catalog.each_case(dialect).each_with_object({}) do |record, unique|
        unique[record.schema] ||= record
      end
      registry = Schemurai::SchemaRegistry.new(schemas: catalog.remotes)

      invalid = records.values.filter_map do |record|
        schema = schema_for_dialect(record.schema, dialect)
        result = registry.validate_schema(schema)
        [record.id, result.errors.map(&:to_h)] unless result.valid?
      end

      expect(invalid).to be_empty, -> { invalid.inspect }
    end
  end
end
