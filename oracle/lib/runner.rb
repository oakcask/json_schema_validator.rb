# frozen_string_literal: true

require "digest"
require "json"
require_relative "case_catalog"
if ENV["SCHEMURAI_ORACLE_REQUIRE"] == "installed"
  require "schemurai"
else
  require_relative "../../lib/schemurai"
end

module SchemuraiOracle
  class Runner
    def initialize(backend:, catalog: CaseCatalog.new)
      @backend = Schemurai.const_get(:Backend).resolve(backend)
      @catalog = catalog
    end

    def run(input)
      operation = input.fetch("operation", "validate")
      context = expand(input)
      result = execute(operation, context)
      base_record(input, operation, context).merge("outcome" => "success", "result" => result)
    rescue Exception => error # rubocop:disable Lint/RescueException -- the oracle records all observable failures
      base_record(input, operation || input["operation"], context).merge(
        "outcome" => "exception",
        "exception" => {"class" => error.class.name, "message" => error.message}
      )
    end

    private def expand(input)
      if input.key?("catalog_case")
        record = @catalog.fetch(input.fetch("catalog_case"))
        return {
          "schema" => record.schema,
          "instance" => record.instance,
          "schemas" => @catalog.remotes,
          "options" => record.options,
          "expected" => record.expected
        }
      end

      {
        "schema" => input["schema"],
        "instance" => input["instance"],
        "schemas" => input.fetch("schemas", {}),
        "options" => input.fetch("options", {}),
        "expected" => input["expected"]
      }
    end

    private def execute(operation, context)
      options = context.fetch("options").transform_keys(&:to_sym)
      common = {schemas: context.fetch("schemas"), backend: @backend, **options}
      case operation
      when "validate"
        result = Schemurai.validate(context.fetch("schema"), context["instance"], **common)
        {"valid" => result.valid?, "errors" => result.errors.map { |error| stringify_keys(error.to_h) }}
      when "valid"
        {"valid" => Schemurai.valid?(context.fetch("schema"), context["instance"], **common)}
      when "compile"
        Schemurai.compile(context.fetch("schema"), **common)
        {"compiled" => true}
      else
        raise ArgumentError, "unknown oracle operation #{operation.inspect}"
      end
    end

    private def base_record(input, operation, context)
      context ||= {}
      {
        "case_id" => input["id"] || input["catalog_case"],
        "backend" => @backend.to_s,
        "ruby_version" => RUBY_VERSION,
        "operation" => operation,
        "schema_fingerprint" => fingerprint(context["schema"]),
        "instance_fingerprint" => fingerprint(context["instance"])
      }
    end

    private def fingerprint(value)
      Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
    end

    private def canonical(value)
      case value
      when Hash
        value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
      when Array
        value.map { |item| canonical(item) }
      else
        value
      end
    end

    private def stringify_keys(hash)
      hash.to_h { |key, value| [key.to_s, value] }
    end
  end
end
