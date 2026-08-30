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

  class CompiledSchema
    def initialize(graph, root)
      @graph = graph
      @root = root
      freeze
    end

    attr_reader :graph, :root
    private :graph, :root
    private_class_method :new
  end

  class SchemaRegistry
    UNDEFINED_SCHEMA = Object.new.freeze
    private_constant :UNDEFINED_SCHEMA

    def initialize(schemas: {})
      @graph = Internal::SchemaGraph.new(schemas: schemas)
    end

    def compile(schema = UNDEFINED_SCHEMA, base_uri: nil, **schema_keywords)
      if schema.equal?(UNDEFINED_SCHEMA)
        raise ArgumentError, "schema is required" if schema_keywords.empty?

        schema = schema_keywords
      elsif !schema_keywords.empty?
        raise ArgumentError, "schema must be passed as one object"
      end

      root = @graph.compile(schema, base_uri: base_uri)
      CompiledSchema.send(:new, @graph, root)
    end
  end

  class Validator
    def initialize(schema = nil, content: false, format: false, **schema_keywords)
      schema = schema_keywords unless schema_keywords.empty?
      unless schema.is_a?(CompiledSchema)
        raise ArgumentError, "schema must be compiled by SchemaRegistry#compile"
      end

      @evaluator = Internal::Evaluator.new(schema, content: content, format: format)
    end

    def validate(instance)
      @evaluator.validate(instance)
    end

    def valid?(instance)
      @evaluator.valid?(instance)
    end
  end

  module_function def compile(*args, schemas: {}, base_uri: nil, **schema_keywords)
    SchemaRegistry.new(schemas: schemas).compile(*args, base_uri: base_uri, **schema_keywords)
  end

  module_function def validate(schema, instance, schemas: {}, base_uri: nil, content: false, format: false)
    compiled = compile(schema, schemas: schemas, base_uri: base_uri)
    Validator.new(compiled, content: content, format: format).validate(instance)
  end

  module_function def valid?(schema, instance, schemas: {}, base_uri: nil, content: false, format: false)
    compiled = compile(schema, schemas: schemas, base_uri: base_uri)
    Validator.new(compiled, content: content, format: format).valid?(instance)
  end
end
