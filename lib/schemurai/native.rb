# frozen_string_literal: true

begin
  require "schemurai/schemurai_native"
rescue LoadError => installed_error
  begin
    require "schemurai_native"
  rescue LoadError
    raise installed_error
  end
end

unless Schemurai::Native::BACKEND == :native
  raise LoadError, "native extension reported an invalid backend identity"
end

module Schemurai
  module Native
    Internal = Schemurai.const_get(:Internal)

    class Resource
      attr_reader :root

      def initialize(root)
        @root = root
        freeze
      end
    end

    class DialectView
      def initialize(ref_siblings:, format_assertion:, supports_min_contains:)
        @ref_siblings = ref_siblings
        @format_assertion = format_assertion
        @keywords = supports_min_contains ? {"minContains" => true}.freeze : {}.freeze
        freeze
      end

      attr_reader :keywords

      def ref_siblings?
        @ref_siblings
      end

      def format_assertion?
        @format_assertion
      end
    end

    class Node
      attr_reader :index, :schema, :dialect, :base_uri, :schema_path,
        :resource_path, :keyword_mask, :format
      attr_accessor :resource

      def initialize(graph, index, metadata)
        @graph = graph
        @index = index
        @schema = metadata.fetch(:schema)
        @dialect = Internal::Dialect.resolve(metadata.fetch(:dialect_uri)) || DialectView.new(
          ref_siblings: metadata.fetch(:ref_siblings),
          format_assertion: metadata.fetch(:format_assertion),
          supports_min_contains: metadata.fetch(:supports_min_contains)
        )
        @base_uri = metadata.fetch(:base_uri)
        @schema_path = metadata.fetch(:schema_path)
        @resource_path = metadata.fetch(:resource_path)
        @resource_root = metadata.fetch(:resource_root)
        @keyword_mask = metadata.fetch(:keyword_mask)
        @format = Internal::Formats.resolve(metadata.fetch(:format)) if metadata.fetch(:format)
      end

      def child(keyword, segment = Internal::SchemaNode.const_get(:MISSING_SEGMENT))
        child_index = if segment.equal?(Internal::SchemaNode.const_get(:MISSING_SEGMENT))
          @graph.child(index, keyword)
        else
          @graph.child(index, keyword, segment)
        end
        @graph.node(child_index) unless child_index.nil?
      end

      def resource_root
        @graph.node(@resource_root)
      end
    end

    class GraphView
      def initialize(graph)
        @graph = graph
        @nodes = Array.new(graph.node_count) do |index|
          Node.new(self, index, graph.node_metadata(index))
        end
        resources = @nodes.to_h { |node| [node.resource_root.index, Resource.new(node.resource_root)] }
        @nodes.each { |node| node.resource = resources.fetch(node.resource_root.index) }
        @nodes.each(&:freeze)
        @nodes.freeze
        freeze
      end

      def root
        node(@graph.root_index)
      end

      def node(index)
        @nodes.fetch(index)
      end

      def child(index, keyword, segment = Internal::SchemaNode.const_get(:MISSING_SEGMENT))
        if segment.equal?(Internal::SchemaNode.const_get(:MISSING_SEGMENT))
          @graph.child(index, keyword)
        else
          @graph.child(index, keyword, segment)
        end
      end

      def resolve(node, reference)
        target = @graph.resolve(node.index, reference)
        raise ResolutionError, "reference #{reference.inspect} was not resolved by native compilation" if target.nil?

        self.node(target)
      end

      def dynamic_anchor(resource, name)
        target = @graph.dynamic_anchor(resource.root.index, name)
        node(target) unless target.nil?
      end

      def dynamic_scope?
        @graph.dynamic_scope?
      end
    end

    Execution = Internal::Evaluator.dup

    class Evaluator
      def initialize(graph, root, content:, format:)
        @graph = graph
        @root = root
        @content = content
        @format = format
        freeze
      end

      def valid?(instance)
        execution.valid?(instance)
      end

      def validate(instance)
        execution.validate(instance)
      end

      private def execution
        Execution.new(@graph, @root, content: @content, format: @format)
      end
    end

    class Validator
      def initialize(snapshot, content: false, format: false)
        @graph = Graph.new(snapshot)
        view = GraphView.new(@graph)
        @evaluator = Evaluator.new(view, view.root, content: content, format: format)
        Ractor.make_shareable(self)
      end

      def valid?(instance)
        @evaluator.valid?(instance)
      end

      def validate(instance)
        @evaluator.validate(instance)
      end

      def __validate_repeated__(instance, iterations)
        iterations.times { @evaluator.valid?(instance) }
      end
    end

    private_constant :Internal, :Resource, :DialectView, :Node, :GraphView, :Execution, :Evaluator
  end
end
