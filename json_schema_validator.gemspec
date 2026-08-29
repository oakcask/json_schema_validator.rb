# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "json_schema_validator"
  spec.version = "0.1.0"
  spec.authors = ["Kuya KOHARA (oakcask)"]
  spec.email = ["kuya.kohara@gmail.com"]

  spec.summary = "A small, light-weight-dependency JSON Schema validator"
  spec.description = "Validates Ruby values against JSON Schema Draft 7, 2019-09, and 2020-12 schemas."
  spec.homepage = "https://github.com/oakcask/json_schema_validator.rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "#{spec.homepage}/tree/main",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "base64"
end
