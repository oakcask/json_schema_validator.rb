# frozen_string_literal: true

module JsonSchemaValidator
  module Internal
    class SchemaNode
      MISSING_SEGMENT = Object.new.freeze
      EMPTY_CHILDREN = {}.freeze

      attr_reader :schema, :dialect, :base_uri, :schema_path, :resource_path,
        :keyword_mask, :document_key
      attr_accessor :resource

      def initialize(schema:, dialect:, base_uri:, schema_path:, resource_path:, document_key:)
        @schema = schema
        @dialect = dialect
        @base_uri = base_uri
        @schema_path = schema_path
        @resource_path = resource_path
        @document_key = document_key
        @keyword_mask = schema.is_a?(Hash) ? dialect.keyword_mask(schema) : 0
        @children = nil
        @children_by_keyword = nil
      end

      def add_child(relative_path, child)
        @children ||= {}
        children[relative_path.freeze] = child
        children_by_keyword = (@children_by_keyword ||= {})
        if relative_path.length == 1
          children_by_keyword[relative_path.first] = child
        else
          (children_by_keyword[relative_path.first] ||= {})[relative_path.last] = child
        end
      end

      def child(keyword, segment = MISSING_SEGMENT)
        return children[keyword] if keyword.is_a?(Array)
        return unless @children_by_keyword
        return @children_by_keyword[keyword] if segment.equal?(MISSING_SEGMENT)

        @children_by_keyword.dig(keyword, segment)
      end

      def children
        @children || EMPTY_CHILDREN
      end

      def freeze
        @children&.freeze
        if @children_by_keyword
          @children_by_keyword.each_value { |value| value.freeze if value.is_a?(Hash) }
          @children_by_keyword.freeze
        end
        super
      end

      private_constant :MISSING_SEGMENT, :EMPTY_CHILDREN
    end
  end

  private_constant :Internal
end
