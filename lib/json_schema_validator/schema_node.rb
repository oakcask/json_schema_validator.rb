# frozen_string_literal: true

require_relative "formats"

module JsonSchemaValidator
  module Internal
    class SchemaNode
      MISSING_SEGMENT = Object.new.freeze

      attr_reader :schema, :dialect, :base_uri, :schema_path, :resource_path,
        :keyword_mask, :document_key, :format
      attr_accessor :resource

      def initialize(schema:, dialect:, base_uri:, schema_path:, resource_path:, document_key:)
        @schema = schema
        @dialect = dialect
        @base_uri = base_uri
        @schema_path = schema_path
        @resource_path = resource_path
        @document_key = document_key
        @keyword_mask = schema.is_a?(Hash) ? dialect.keyword_mask(schema) : 0
        @format = Formats.resolve(schema["format"]) if schema.is_a?(Hash) && schema.key?("format")
        @children = nil
      end

      def add_child(keyword, segment = MISSING_SEGMENT, child:)
        children = (@children ||= {})
        if segment.equal?(MISSING_SEGMENT)
          children[keyword] = child
        else
          (children[keyword] ||= {})[segment] = child
        end
      end

      def child(keyword, segment = MISSING_SEGMENT)
        return unless @children
        return @children[keyword] if segment.equal?(MISSING_SEGMENT)

        @children.dig(keyword, segment)
      end

      def freeze
        if @children
          @children.each_value { |value| value.freeze if value.is_a?(Hash) }
          @children.freeze
        end
        super
      end

      private_constant :MISSING_SEGMENT
    end
  end

  private_constant :Internal
end
