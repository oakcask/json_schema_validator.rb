# frozen_string_literal: true

require "open3"
require_relative "spec_helper"

RSpec.describe "backend selection" do
  it "makes selection and actual identity observable", :aggregate_failures do
    registry = Schemurai::SchemaRegistry.new(backend: :ruby)
    validator = registry.compile(true)

    expect(Schemurai.backend).to eq(:ruby)
    expect(registry.backend).to eq(:ruby)
    expect(validator.backend).to eq(:ruby)
  end

  it "rejects an unknown backend" do
    expect { Schemurai.compile(true, backend: :unknown) }
      .to raise_error(Schemurai::Error, /unknown Schemurai backend/)
  end

  it "fails strict native selection without falling back" do
    expect { Schemurai.compile(true, backend: :native) }
      .to raise_error(LoadError, /native backend is unavailable/)
  end

  it "prohibits native loading in a Ruby-only process", :aggregate_failures do # rubocop:disable RSpec/ExampleLength
    script = <<~RUBY
      require "schemurai"
      abort unless Schemurai.backend == :ruby
      abort if Schemurai.const_get(:Backend).native_available?
      abort if $LOADED_FEATURES.any? { |feature| feature.include?("schemurai/native") }
    RUBY
    environment = {"SCHEMURAI_BACKEND" => "ruby", "SCHEMURAI_NATIVE_LOADING" => "prohibited"}
    _output, error, status = Open3.capture3(environment, Gem.ruby, "-Ilib", "-e", script)

    expect(error).to be_empty
    expect(status).to be_success
  end
end
