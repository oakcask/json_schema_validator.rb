# frozen_string_literal: true

module JsonSchemaValidator
  module Internal
    class SchemaNode
      attr_reader :schema, :dialect, :base_uri, :schema_path, :resource_path,
        :keyword_mask, :children, :document_key
      attr_accessor :resource

      def initialize(schema:, dialect:, base_uri:, schema_path:, resource_path:, document_key:)
        @schema = schema
        @dialect = dialect
        @base_uri = base_uri
        @schema_path = schema_path
        @resource_path = resource_path
        @document_key = document_key
        @keyword_mask = schema.is_a?(Hash) ? dialect.keyword_mask(schema) : 0
        @children = {}
      end

      def add_child(relative_path, child)
        children[relative_path.freeze] = child
      end

      def child(relative_path)
        children[Array(relative_path)]
      end

      def freeze
        children.freeze
        super
      end
    end
  end

  private_constant :Internal
end
