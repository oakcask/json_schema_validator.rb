# frozen_string_literal: true

require "json"
require "rspec"
require "schemurai"
require "schemurai/native"
require_relative "../native/source/bootstrap"

RSpec.describe "native intrinsic contracts" do
  values = [true, false, nil, 0, 1.5, "true", [], {}].freeze
  builtin_classes = [Hash, Array, String, Integer, Float].freeze

  it "reports native identity" do
    expect(Schemurai::Native::BACKEND).to eq(:native)
  end

  it "presents strict native validation dispatch" do
    expect(Schemurai.const_get(:Backend).native_available?).to be(true)
    expect(Schemurai.compile(true, backend: :native).backend).to eq(:native)
  end

  it "is callable from a non-main Ractor" do
    ractor = Ractor.new { Schemurai::Native::Intrinsics.boolean_instance?(true) }
    result = ractor.respond_to?(:value) ? ractor.value : ractor.take

    expect(result).to be(true)
  end

  it "matches the generated boolean source" do
    values.each do |value|
      expected = Schemurai::NativeSource.boolean_instance?(value)
      actual = Schemurai::Native::Intrinsics.boolean_instance?(value)
      expect(actual).to eq(expected), "value: #{value.inspect}"
    end
  end

  it "matches exact built-in class guards, including subclasses" do
    subclass = Class.new(Hash)
    instances = [{}, [], "value", 1, 1.5, subclass.new]

    builtin_classes.each do |klass|
      instances.each do |value|
        expected = value.instance_of?(klass)
        actual = Schemurai::Native::Intrinsics.exact_builtin?(value, klass)
        expect(actual).to eq(expected), "value: #{value.inspect}, class: #{klass}"
      end
    end
  end

  it "matches exceptional class-argument behavior" do
    ruby_error = begin
      Object.new.instance_of?(Object.new)
    rescue TypeError => error
      error
    end
    expect { Schemurai::Native::Intrinsics.exact_builtin?(Object.new, Object.new) }
      .to raise_error(TypeError, ruby_error.message)
  end

  it "matches finite and integral Float operations" do
    [0.0, 1.0, -2.0, 1.5, -2.25, Float::NAN, Float::INFINITY, -Float::INFINITY].each do |value|
      expect(Schemurai::Native::Intrinsics.finite_float?(value)).to eq(value.finite?)
      expect(Schemurai::Native::Intrinsics.integral_float?(value)).to eq(value.to_i == value) if value.finite?
    end
  end

  it "rejects unrefined operands for Float operations" do
    expect { Schemurai::Native::Intrinsics.finite_float?(1) }.to raise_error(TypeError)
    expect { Schemurai::Native::Intrinsics.integral_float?(1) }.to raise_error(TypeError)
  end

  it "matches unsigned type-mask intersection" do
    expect(Schemurai::Native::Intrinsics.mask_intersects?(5, 1)).to be(true)
    expect(Schemurai::Native::Intrinsics.mask_intersects?(4, 2)).to be(false)
    expect { Schemurai::Native::Intrinsics.mask_intersects?("4", 2) }.to raise_error(TypeError)
  end

  it "has manifest entries for every executable intrinsic and no generic calls" do
    manifest = JSON.parse(File.read("native/intrinsics.json"))
    names = manifest.fetch("intrinsics").map { |entry| entry.fetch("name") }

    expect(names).to eq(%w[object_identity exact_builtin_guard finite_float integral_float mask_intersects])
    expect(manifest.fetch("generic_calls").map { |entry| entry.fetch("classification") }.uniq)
      .to eq(["cold_out_of_domain_compatibility"])
  end
end
