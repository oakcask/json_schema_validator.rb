# frozen_string_literal: true

require_relative "../../oracle/lib/case_catalog"

module OfficialSuite
  module_function def define(example_group, dialect)
    catalog = SchemuraiOracle::CaseCatalog.new
    catalog.verify_counts!
    remotes = catalog.remotes

    catalog.each_case(dialect).each do |record|
      definition = (record.classification == "selected") ? example_group.method(:it) : example_group.method(:xit)
      definition.call(record.description, :aggregate_failures, oracle_case_id: record.id) do
        options = record.options.transform_keys(&:to_sym)
        result = Schemurai.validate(record.schema, record.instance, schemas: remotes, **options)
        expect(result.valid?).to eq(record.expected), -> { result.errors.map(&:to_h).inspect }
        expect(Schemurai.valid?(record.schema, record.instance, schemas: remotes, **options)).to eq(record.expected)
      end
    end
  end
end
