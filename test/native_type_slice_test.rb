# frozen_string_literal: true

require "json"
require "open3"
require "timeout"
require "rspec"
require "schemurai"
require "schemurai/native"

type_cases = [
  ["null", nil, true], ["null", false, false],
  ["boolean", true, true], ["boolean", nil, false],
  ["object", {}, true], ["object", [], false],
  ["array", [], true], ["array", {}, false],
  ["number", 1, true], ["number", 1.5, true], ["number", "1", false],
  ["integer", 1, true], ["integer", 1.0, true], ["integer", 1.5, false],
  ["string", "value", true], ["string", 1, false]
].freeze

RSpec.describe "native type vertical slice" do
  it "matches the Ruby backend for every JSON type and a type union" do
    type_cases.each do |type, instance, expected|
      schema = {"type" => type}
      expect(Schemurai.valid?(schema, instance, backend: :ruby)).to eq(expected)
      expect(Schemurai.valid?(schema, instance, backend: :native)).to eq(expected)
    end

    schema = {"type" => %w[string null]}
    expect(Schemurai.valid?(schema, nil, backend: :native)).to be(true)
    expect(Schemurai.valid?(schema, 1, backend: :native)).to be(false)
  end

  it "preserves contractual type behavior outside the supported JSON domain" do
    values = [
      [{"type" => "string"}, Class.new(String).new("value")],
      [{"type" => "object"}, Class.new(Hash).new],
      [{"type" => "array"}, Class.new(Array).new],
      [{"type" => "number"}, Rational(1, 2)],
      [{"type" => "integer"}, Rational(2, 1)],
      [{"type" => "integer"}, Rational(1, 2)],
      [{"type" => "number"}, Complex(1, 0)],
      [{"type" => "integer"}, Float::NAN],
      [{"type" => "integer"}, Float::INFINITY]
    ]

    values.each do |schema, instance|
      expect(Schemurai.valid?(schema, instance, backend: :native))
        .to eq(Schemurai.valid?(schema, instance, backend: :ruby))
    end
  end

  it "matches detailed type and false-schema errors" do
    [
      [{"type" => %w[string null]}, 1],
      [false, "anything"]
    ].each do |schema, instance|
      ruby_errors = Schemurai.validate(schema, instance, backend: :ruby).errors.map(&:to_h)
      native_errors = Schemurai.validate(schema, instance, backend: :native).errors.map(&:to_h)
      expect(native_errors).to eq(ruby_errors)
    end
  end

  it "rejects unsupported native keywords without Ruby evaluator fallback" do
    expect { Schemurai.compile({"type" => "integer", "minimum" => 1}, backend: :native) }
      .to raise_error(Schemurai::Error, /native type slice does not support "minimum"/)
  end

  it "runs forced Ruby and native differential records in separate processes" do # rubocop:disable RSpec/ExampleLength
    inputs = type_cases.each_with_index.map do |(type, instance, _expected), index|
      JSON.generate("id" => "type-#{index}", "operation" => "validate", "schema" => {"type" => type}, "instance" => instance)
    end.join("\n") << "\n"

    ruby_output, ruby_error, ruby_status = run_oracle("ruby", inputs)
    native_output, native_error, native_status = run_oracle("native", inputs)
    expect([ruby_error, native_error]).to eq(["", ""])
    expect([ruby_status.success?, native_status.success?]).to eq([true, true])

    ruby_records = ruby_output.lines.map { |line| JSON.parse(line) }
    native_records = native_output.lines.map { |line| JSON.parse(line) }
    ruby_records.zip(native_records).each do |ruby_record, native_record|
      expect(native_record.fetch("backend")).to eq("native")
      expect(native_record.fetch("result")).to eq(ruby_record.fetch("result"))
    end
  end

  it "retains one compactable schema in a frozen shareable typed-data graph" do
    schema = {"type" => %w[integer null]}
    validator = Schemurai.compile(schema, backend: :native)
    graph = validator.instance_variable_get(:@evaluator).instance_variable_get(:@graph)

    expect(graph.schema).to equal(schema)
    expect(graph).to be_frozen
    expect(graph.shareable_state?).to be(true)
    expect(Ractor.shareable?(graph)).to be(true)
    expect(Ractor.shareable?(validator)).to be(true)

    GC.stress = true
    GC.start
    GC.compact
    expect(validator.valid?(3)).to be(true)
    expect(validator.valid?(3.5)).to be(false)
  ensure
    GC.stress = false
  end

  it "does not publish shareable state when the shareability transition raises" do
    graph = Schemurai::Native::Graph.__for_shareability_test__({"retained" => Thread.current})

    expect { graph.__make_shareable__ }.to raise_error(Ractor::Error)
    expect(graph.shareable_state?).to be(false)
    expect(Ractor.shareable?(graph)).to be(false)
  end

  it "survives a forced compatibility exception and remains reusable" do
    exceptional = Class.new(Numeric) do
      def finite? = raise("finite failed")
    end.new
    validator = Schemurai.compile({"type" => "integer"}, backend: :native)

    expect { validator.valid?(exceptional) }.to raise_error(RuntimeError, "finite failed")
    expect(validator.valid?(2)).to be(true)
    expect(validator.valid?(2.5)).to be(false)
  end

  it "observes asynchronous interrupts in a long native loop" do
    validator = Schemurai.compile({"type" => "integer"}, backend: :native)
    started = Queue.new
    worker = Thread.new do
      started << true
      validator.instance_variable_get(:@evaluator).__validate_repeated__(1, 1_000_000_000)
    end
    worker.report_on_exception = false
    started.pop
    worker.raise(Interrupt)

    expect { Timeout.timeout(5) { worker.value } }.to raise_error(Interrupt)
    expect(validator.valid?(1)).to be(true)
  ensure
    worker&.kill
  end

  it "supports concurrent threads and independent non-main Ractors" do
    validator = Schemurai.compile({"type" => "integer"}, backend: :native)
    results = 8.times.map do |index|
      Thread.new { 1_000.times.all? { validator.valid?(index) && !validator.valid?(index + 0.5) } }
    end.map(&:value)
    expect(results).to all(be(true))

    ractors = 2.times.map do
      Ractor.new(validator) { |shared| [shared.backend, shared.valid?(4), shared.valid?(4.5)] }
    end
    expect(ractors.map { |ractor| ractor.respond_to?(:value) ? ractor.value : ractor.take })
      .to eq([[:native, true, false], [:native, true, false]])
  end

  it "contains no generic dispatch in the supported validation hot path" do
    source = File.read("ext/schemurai/generated_bootstrap.c")
    hot_path = source[/int\nschemurai_generated_valid_type.*?^}/m]

    expect(hot_path).not_to include("rb_funcall")
    expect(source).not_to include("rb_funcallv")
    expect(source.scan("cold_out_of_domain_compatibility").length).to eq(3)
  end

  def run_oracle(backend, input)
    Open3.capture3(
      Gem.ruby,
      "-Ilib",
      "-Iext/schemurai",
      "script/oracle-runner",
      "--backend",
      backend,
      stdin_data: input
    )
  end
end
