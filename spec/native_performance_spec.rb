# frozen_string_literal: true

require "json"
require_relative "spec_helper"

RSpec.describe "native production default evidence" do
  let(:decision) { JSON.parse(File.read("benchmark/production_default.json")) }
  let(:records) do
    decision.fetch("evidence").map do |path|
      JSON.parse(File.read(File.join("benchmark", path)))
    end
  end

  it "ties the production selection to complete interpreter and YJIT samples" do # rubocop:disable RSpec/ExampleLength, RSpec/MultipleExpectations
    expect(records.map { |record| record.fetch("yjit") }).to contain_exactly(false, true)
    records.each do |record|
      sample_count = record.dig("configuration", "samples")
      expect(record.dig("corpus", "selected_cases")).to eq(1_877)
      expect(record.fetch("correctness_sha256")).to match(/\A[0-9a-f]{64}\z/)
      expect(record.dig("native_memory", "graph_bytes")).to be_positive

      decision.fetch("required_timed_workloads").each do |workload|
        %w[ruby native].each do |backend|
          expect(record.dig("workloads", backend, workload).length).to eq(sample_count)
        end
      end
      decision.fetch("required_concurrency_workloads").each do |workload|
        %w[ruby native].each do |backend|
          expect(record.dig("concurrency", workload, backend).length).to eq(sample_count)
        end
      end
    end
  end

  it "uses the recorded production selection" do
    expect(Schemurai.const_get(:Backend).production_default.to_s).to eq(decision.fetch("selected_backend"))
  end
end
