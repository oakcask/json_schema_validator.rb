# frozen_string_literal: true

require "spec_helper"
require_relative "../oracle/lib/runner"
require_relative "../oracle/lib/comparator"

backend = ENV.fetch("SCHEMURAI_DIFFERENTIAL_BACKEND").to_sym

RSpec.describe "the #{backend} evaluator" do
  it "does not instantiate or copy the Ruby evaluator" do
    ruby_evaluator = Schemurai.const_get(:Internal).const_get(:Evaluator)
    allow(ruby_evaluator).to receive(:new).and_raise("Ruby evaluator fallback")
    allow(ruby_evaluator).to receive(:dup).and_raise("Ruby evaluator copy")

    validator = Schemurai.compile({"type" => "integer"}, backend: backend)
    expect(validator.valid?(4)).to be(true)
    expect(validator.valid?(4.5)).to be(false)
  end

  it "matches the Ruby result stream for the complete catalog" do
    inputs = SchemuraiOracle::CaseCatalog.new.each_case
      .select { |record| record.classification == "selected" }
      .map { |record| {"catalog_case" => record.id} }
    ruby_runner = SchemuraiOracle::Runner.new(backend: :ruby)
    backend_runner = SchemuraiOracle::Runner.new(backend: backend)
    ruby_records = inputs.map { |input| ruby_runner.run(input) }
    backend_records = inputs.map { |input| backend_runner.run(input) }
    comparison = SchemuraiOracle::Comparator.new(actual_backend: backend.to_s)
      .compare(ruby_records, backend_records)

    expect(comparison).to be_empty
  end
end
