# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../oracle/lib/case_catalog"
require_relative "../oracle/lib/comparator"
require_relative "../oracle/lib/runner"

RSpec.describe "the Ruby oracle" do
  it "keeps every official case classified with reviewed counts" do
    expect(SchemuraiOracle::CaseCatalog.new.verify_counts!).to be(true)
  end

  it "keeps the reviewed canonical Ruby records current" do # rubocop:disable RSpec/ExampleLength
    runner = SchemuraiOracle::Runner.new(backend: :ruby)
    inputs = File.readlines(File.expand_path("../oracle/fixtures/contract_cases.jsonl", __dir__), chomp: true)
      .map { |line| JSON.parse(line) }
    expected = File.readlines(File.expand_path("../oracle/records/ruby-4.0.jsonl", __dir__), chomp: true)
      .map { |line| JSON.parse(line) }
    actual = inputs.map { |input| runner.run(input) }
    comparator = SchemuraiOracle::Comparator.new(expected_backend: "ruby", actual_backend: "ruby")

    expect(comparator.compare(expected, actual)).to be_empty
  end

  it "emits the public ValidationError fields without sorting errors", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    runner = SchemuraiOracle::Runner.new(backend: :ruby)
    record = runner.run(
      "id" => "errors",
      "operation" => "validate",
      "schema" => {"type" => "object", "required" => ["first", "second"]},
      "instance" => {}
    )

    expect(record).to include("backend" => "ruby", "outcome" => "success")
    errors = record.fetch("result").fetch("errors")
    expect(errors.map { |error| error.fetch("keyword") }).to eq(%w[required required])
    expect(errors).to all(include("instance_path" => "", "schema_path" => "/required", "message" => be_a(String)))
  end

  it "compares behavior while retaining backend diagnostics" do
    expected = [{"case_id" => "one", "operation" => "valid", "backend" => "ruby", "result" => {"valid" => true}}]
    actual = [{"case_id" => "one", "operation" => "valid", "backend" => "vm", "result" => {"valid" => true}}]

    expect(SchemuraiOracle::Comparator.new.compare(expected, actual)).to be_empty
  end

  it "rejects a VM stream that silently identifies as Ruby" do
    expected = [{"case_id" => "one", "operation" => "valid", "backend" => "ruby", "result" => {"valid" => true}}]
    fallback = [{"case_id" => "one", "operation" => "valid", "backend" => "ruby", "result" => {"valid" => true}}]

    expect(SchemuraiOracle::Comparator.new.compare(expected, fallback).join)
      .to include("actual record used backend")
  end

  it "reports observable mismatches" do
    expected = [{"case_id" => "one", "operation" => "valid", "result" => {"valid" => true}}]
    actual = [{"case_id" => "one", "operation" => "valid", "result" => {"valid" => false}}]

    comparator = SchemuraiOracle::Comparator.new(expected_backend: nil, actual_backend: nil)
    expect(comparator.compare(expected, actual)).not_to be_empty
  end

  it "does not treat validation message wording as compatible behavior" do
    expected = [{"case_id" => "one", "operation" => "validate", "result" => {"errors" => [{"message" => "first"}]}}]
    actual = [{"case_id" => "one", "operation" => "validate", "result" => {"errors" => [{"message" => "second"}]}}]

    expect(SchemuraiOracle::Comparator.new(expected_backend: nil, actual_backend: nil).compare(expected, actual)).to be_empty
  end

  it "retains validation message presence and type as compatible behavior" do
    expected = [{"case_id" => "one", "operation" => "validate", "result" => {"errors" => [{"message" => "text"}]}}]
    actual = [{"case_id" => "one", "operation" => "validate", "result" => {"errors" => [{"message" => nil}]}}]

    expect(SchemuraiOracle::Comparator.new(expected_backend: nil, actual_backend: nil).compare(expected, actual)).not_to be_empty
  end
end
