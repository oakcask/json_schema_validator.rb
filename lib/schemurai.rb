# frozen_string_literal: true

require_relative "schemurai/version"
require_relative "schemurai/backend"
require_relative "schemurai/formats"
require_relative "schemurai/schema_graph"
require_relative "schemurai/evaluator"

module Schemurai
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
    attr_reader :backend

    def initialize(schemas: {}, backend: Backend.requested)
      @backend = Backend.resolve(backend)
      @graph = Internal::SchemaGraph.new(schemas: schemas)
      @compiler = VM::Compiler.new(@graph) if @backend == :vm
    end

    def compile(schema, base_uri: nil, content: false, format: false)
      raise Error, "cannot compile schemas after the registry is made shareable" if shareable?

      root = @graph.compile(schema, base_uri: base_uri)
      build_validator(root, content: content, format: format)
    end

    def make_shareable
      return self if shareable?

      @graph.make_shareable
      @compiler&.compile_all
      Ractor.make_shareable(self)
    end

    def shareable?
      Ractor.shareable?(self)
    end

    def validator_for(uri, content: false, format: false)
      raise Error, "make_shareable must be called before retrieving validators by URI" unless shareable?

      root = @graph.node_at(uri)
      raise ResolutionError, "unregistered schema URI #{uri.inspect}" unless root

      build_validator(root, content: content, format: format)
    end

    private def build_validator(root, content:, format:)
      evaluator = if @compiler
        program = @compiler.compile(root)
        VM::Evaluator.new(@graph, @compiler, program, content: content, format: format)
      else
        Internal::Evaluator.new(@graph, root, content: content, format: format)
      end
      Validator.new(evaluator)
    end
  end

  class Validator
    def initialize(evaluator)
      @evaluator = evaluator
    end

    def backend
      @evaluator.backend
    end

    def validate(instance)
      @evaluator.validate(instance)
    end

    def valid?(instance)
      @evaluator.valid?(instance)
    end
  end

  module_function def backend
    Backend.resolve
  end

  module_function def compile(schema, schemas: {}, base_uri: nil, content: false, format: false, backend: Backend.requested)
    SchemaRegistry.new(schemas: schemas, backend: backend).compile(
      schema,
      base_uri: base_uri,
      content: content,
      format: format
    )
  end

  module_function def validate(schema, instance, schemas: {}, base_uri: nil, content: false, format: false, backend: Backend.requested)
    compile(
      schema,
      schemas: schemas,
      base_uri: base_uri,
      content: content,
      format: format,
      backend: backend
    ).validate(instance)
  end

  module_function def valid?(schema, instance, schemas: {}, base_uri: nil, content: false, format: false, backend: Backend.requested)
    compile(
      schema,
      schemas: schemas,
      base_uri: base_uri,
      content: content,
      format: format,
      backend: backend
    ).valid?(instance)
  end

  private_constant :Backend
end
