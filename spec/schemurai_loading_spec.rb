# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "spec_helper"

RSpec.describe Schemurai do
  def run_in_fresh_process(script)
    project_root = File.expand_path("..", __dir__)
    _, stderr, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script, chdir: project_root)
    [status, stderr]
  end

  let(:draft2020_dialect_script) do
    <<~RUBY
      require "schemurai/dialects/draft2020_12"

      loaded = $LOADED_FEATURES.grep(%r{/schemurai/(?:dialects|meta_schemas)/})
      expected = ["schemurai/dialects/draft2020_12.rb"]
      abort loaded.inspect unless loaded.map { |path| path.split("/lib/").last } == expected
    RUBY
  end

  let(:draft2020_meta_schema_script) do
    <<~RUBY
      require "schemurai/meta_schemas/draft2020_12"

      loaded = $LOADED_FEATURES.grep(%r{/schemurai/(?:dialects/|dialect_keywords[.]rb)})
      abort loaded.inspect unless loaded.empty?
    RUBY
  end

  it "loads Draft 2020-12 dialect keywords without loading older drafts or meta-schemas" do
    status, stderr = run_in_fresh_process(draft2020_dialect_script)
    expect(status).to be_success, stderr
  end

  it "loads the Draft 2020-12 meta-schema without loading dialect keywords" do
    status, stderr = run_in_fresh_process(draft2020_meta_schema_script)
    expect(status).to be_success, stderr
  end
end
