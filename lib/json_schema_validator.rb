# frozen_string_literal: true

require_relative "json_schema_validator/formats"
require_relative "json_schema_validator/schema_graph"
require_relative "json_schema_validator/evaluator"

module JsonSchemaValidator
  class Error < StandardError; end
  class ResolutionError < Error; end
  class UnsupportedFormatError < Error; end

  ValidationError = Data.define(:keyword, :instance_path, :schema_path, :message) do
    def to_h
      {keyword: keyword, instance_path: instance_path, schema_path: schema_path, message: message}
    end
  end

  class Result
    attr_reader :errors

    def initialize(errors)
      @errors = errors.freeze
    end

    def valid?
      errors.empty?
    end

    alias_method :success?, :valid?
  end

  class SchemaRegistry
    def initialize(schemas: {})
      @graph = Internal::SchemaGraph.new(schemas: schemas)
    end

    def compile(schema, base_uri: nil, content: false, format: false)
      root = @graph.compile(schema, base_uri: base_uri)
      Validator.new(@graph, root, content: content, format: format)
    end
  end

  class Validator
    def initialize(graph, root, content:, format:)
      @evaluator = Internal::Evaluator.new(graph, root, content: content, format: format)
    end

    def validate(instance)
      @evaluator.validate(instance)
    end

    def valid?(instance)
      @evaluator.valid?(instance)
    end
  end

  module_function def compile(schema, schemas: {}, base_uri: nil, content: false, format: false)
    SchemaRegistry.new(schemas: schemas).compile(
      schema,
      base_uri: base_uri,
      content: content,
      format: format
    )
  end

  module_function def validate(schema, instance, schemas: {}, base_uri: nil, content: false, format: false)
    compile(
      schema,
      schemas: schemas,
      base_uri: base_uri,
      content: content,
      format: format
    ).validate(instance)
  end

  module_function def valid?(schema, instance, schemas: {}, base_uri: nil, content: false, format: false)
    compile(
      schema,
      schemas: schemas,
      base_uri: base_uri,
      content: content,
      format: format
    ).valid?(instance)
  end
end
