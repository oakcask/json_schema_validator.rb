# frozen_string_literal: true

require "json"
require_relative "../lib/schemurai"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random

  assert_ruby_only = lambda do
    next unless ENV["SCHEMURAI_NATIVE_LOADING"] == "prohibited"

    raise "Ruby oracle did not select the Ruby backend" unless Schemurai.backend == :ruby
    if $LOADED_FEATURES.any? { |feature| feature.include?("schemurai/native") }
      raise "native backend was loaded during a Ruby-only suite"
    end
  end

  config.before(:suite) { assert_ruby_only.call }
  config.after(:suite) { assert_ruby_only.call }
end
