# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "JSON Schema Draft 7 official suite" do
  suite_root = File.expand_path("../references/JSON-Schema-Test-Suite", __dir__)
  let(:remotes) do
    remote_root = File.expand_path("../references/JSON-Schema-Test-Suite/remotes", __dir__)
    Dir[File.join(remote_root, "**", "*.json")].to_h do |file|
      relative = file.delete_prefix("#{remote_root}/")
      ["http://localhost:1234/#{relative}", JSON.parse(File.read(file))]
    end
  end

  Dir[File.join(suite_root, "tests", "draft7", "*.json")].sort.each do |file|
    JSON.parse(File.read(file)).each do |group|
      group.fetch("tests").each do |test|
        it "#{File.basename(file)}: #{group.fetch("description")} / #{test.fetch("description")}" do
          result = JsonSchemaValidator.validate(group.fetch("schema"), test.fetch("data"), schemas: remotes)
          expect(result.valid?).to eq(test.fetch("valid")), -> { result.errors.map(&:to_h).inspect }
        end
      end
    end
  end

  optional_files = Dir[File.join(suite_root, "tests", "draft7", "optional", "*.json")]
  optional_files.reject! { |file| File.basename(file) == "cross-draft.json" }
  optional_files.sort.each do |file|
    JSON.parse(File.read(file)).each do |group|
      group.fetch("tests").each do |test|
        it "optional/#{File.basename(file)}: #{group.fetch("description")} / #{test.fetch("description")}" do
          result = JsonSchemaValidator.validate(group.fetch("schema"), test.fetch("data"), schemas: remotes, content: true)
          expect(result.valid?).to eq(test.fetch("valid")), -> { result.errors.map(&:to_h).inspect }
        end
      end
    end
  end
end
