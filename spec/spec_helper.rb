# frozen_string_literal: true

require "json"
require_relative "../lib/json_schema_validator"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
end
