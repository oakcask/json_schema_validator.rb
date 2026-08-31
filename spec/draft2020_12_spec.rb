# frozen_string_literal: true

require_relative "spec_helper"
require_relative "support/official_suite"

# Examples are defined from the reviewed machine-readable catalog.
RSpec.describe "JSON Schema Draft 2020-12 official suite" do # rubocop:disable RSpec/EmptyExampleGroup
  OfficialSuite.define(self, "draft2020-12")
end
