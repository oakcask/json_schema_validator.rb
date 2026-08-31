# frozen_string_literal: true

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
    def initialize(schemas: {})
      @graph = Internal::SchemaGraph.new(schemas: schemas)
      @shareable = false
    end

    def compile(schema, base_uri: nil, content: false, format: false)
      raise Error, "cannot compile schemas after the registry is made shareable" if @shareable

      root = @graph.compile(schema, base_uri: base_uri)
      Validator.new(@graph, root, content: content, format: format)
    end

    def make_shareable
      return self if @shareable

      @graph.make_shareable
      @shareable = true
      Ractor.make_shareable(self)
    end

    def shareable?
      @shareable
    end

    def validator_for(uri, content: false, format: false)
      raise Error, "make_shareable must be called before retrieving validators by URI" unless @shareable

      root = @graph.node_at(uri)
      raise ResolutionError, "unregistered schema URI #{uri.inspect}" unless root

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
