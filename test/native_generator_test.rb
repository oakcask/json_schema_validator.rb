# frozen_string_literal: true

require "tmpdir"
require "rspec"
require_relative "../tool/native_generator"

RSpec.describe Schemurai::NativeGenerator do
  def compile(body)
    source = <<~RUBY
      def self.boolean_instance?(instance)
        #{body}
      end
    RUBY
    described_class.compile(source, source_name: "fixture.rb")
  end

  it "validates complete, typed manifests" do
    expect(described_class.validate_manifests!).to be(true)
  end

  it "reproduces the committed output byte for byte" do
    Dir.mktmpdir do |directory|
      output = File.join(directory, "generated_bootstrap.c")
      described_class.generate(output)

      expect(File.binread(output)).to eq(File.binread("ext/schemurai/generated_bootstrap.c"))
    end
  end

  it "lowers every supported expression to typed intrinsic IR" do
    ir = compile("true.equal?(instance) || false.equal?(instance)")

    expect(ir).to eq(
      name: :boolean_instance?,
      parameters: [:instance],
      result: :c_boolean,
      expression: {
        op: :or,
        left: {op: :intrinsic, name: "object_identity", operands: [{op: :literal, value: true}, {op: :argument, name: :instance}]},
        right: {op: :intrinsic, name: "object_identity", operands: [{op: :literal, value: false}, {op: :argument, name: :instance}]}
      }
    )
  end

  it "rejects an unknown receiver without a class guard" do
    expect { compile("instance.empty?") }
      .to raise_error(described_class::GenerationError, /fixture\.rb:2: missing class guard for ambiguous receiver instance/)
  end

  it "rejects implicit generic dispatch" do
    expect { compile("unknown_operation(instance)") }
      .to raise_error(described_class::GenerationError, /implicit generic dispatch unknown_operation is not allowlisted/)
  end

  it "rejects unsupported syntax with a source location" do
    expect { compile("if instance\n true\n end") }
      .to raise_error(described_class::GenerationError, /fixture\.rb:2: unsupported syntax IfNode/)
  end
end
