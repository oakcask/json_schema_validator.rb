# frozen_string_literal: true

require "json"

module SchemuraiOracle
  class Comparator
    METADATA_KEYS = %w[backend ruby_version].freeze

    def initialize(expected_backend: "ruby", actual_backend: "vm")
      @expected_backend = expected_backend
      @actual_backend = actual_backend
    end

    def compare(expected_records, actual_records)
      mismatches = []
      expected_by_key = index(expected_records, "expected", @expected_backend, mismatches)
      actual_by_key = index(actual_records, "actual", @actual_backend, mismatches)

      (expected_by_key.keys | actual_by_key.keys).sort.each do |key|
        expected = expected_by_key[key]
        actual = actual_by_key[key]
        if expected.nil? || actual.nil?
          mismatches << {"case" => key, "expected" => expected, "actual" => actual}
        elsif semantic_record(expected) != semantic_record(actual)
          mismatches << {"case" => key, "expected" => expected, "actual" => actual}
        end
      end
      mismatches
    end

    private def index(records, label, required_backend, mismatches)
      records.each_with_object({}) do |record, indexed|
        key = [record["case_id"], record["operation"]]
        if required_backend && record["backend"] != required_backend
          mismatches << {
            "case" => key,
            "error" => "#{label} record used backend #{record["backend"].inspect}, expected #{required_backend.inspect}"
          }
        end
        if indexed.key?(key)
          mismatches << {"case" => key, "error" => "duplicate #{label} record"}
        else
          indexed[key] = record
        end
      end
    end

    private def semantic_record(record)
      record.except(*METADATA_KEYS)
    end
  end
end
