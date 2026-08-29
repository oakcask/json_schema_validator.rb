# frozen_string_literal: true

require "uri"
require_relative "dialects/draft7"
require_relative "schema_node"

module JsonSchemaValidator
  module Internal
    class SchemaGraph
      class Resource
        attr_reader :uri, :root, :nodes

        def initialize(uri, root)
          @uri = uri
          @root = root
          @nodes = {}
        end

        def add(node)
          nodes[node.resource_path] = node
          node.resource = self
        end

        def node_at(pointer)
          nodes[pointer]
        end
      end

      attr_reader :root, :resources, :uri_registry, :nodes

      def initialize(schema, schemas: {}, base_uri: nil, dialect: Dialect.resolve)
        @external_schemas = schemas
        @indexed_external_schemas = {}
        @resources = {}
        @uri_registry = {}
        @nodes = []
        @nodes_by_document_location = {}

        root_dialect = dialect_for(schema, dialect)
        meta_uri = root_dialect.uri
        @external_schemas = {meta_uri => root_dialect.meta_schema}.merge(schemas)
        @root = compile_document(schema, base_uri.to_s, root_dialect)
      end

      def resolve(node, reference)
        uri = absolute_uri(node.base_uri, reference)
        document_uri = strip_fragment(uri)
        index_external(document_uri)

        if (target = uri_registry[uri])
          return target
        end

        resource = resources[document_uri]
        raise ResolutionError, "unresolvable reference #{reference.inspect}" unless resource

        raw_fragment = fragment(uri)
        return resource.root if raw_fragment.empty?

        decoded = URI.decode_uri_component(raw_fragment)
        unless decoded.start_with?("/")
          raise ResolutionError, "unsupported plain-name fragment ##{raw_fragment}"
        end

        pointer = canonical_pointer(decoded)
        return resource.node_at(pointer) if resource.node_at(pointer)

        schema_path = "#{resource.root.schema_path}#{pointer}"
        location = [resource.root.document_key, schema_path]
        return @nodes_by_document_location[location] if @nodes_by_document_location.key?(location)

        target = pointer_target(resource.root.schema, pointer)
        compile(
          target,
          resource.root.base_uri,
          resource.root.dialect,
          schema_path,
          pointer,
          resource,
          resource.root.document_key
        )
      rescue URI::Error
        raise ResolutionError, "unresolvable reference #{reference.inspect}"
      end

      def node_at(uri)
        uri_registry[uri.to_s]
      end

      private def compile_document(schema, retrieval_uri, dialect)
        root = compile(schema, retrieval_uri, dialect, "", "", nil, Object.new)
        document_uri = strip_fragment(retrieval_uri)
        register_resource(document_uri, root) unless resources.key?(document_uri)
        uri_registry[retrieval_uri] ||= root unless retrieval_uri.empty?
        uri_registry[document_uri] ||= root unless document_uri.empty?
        root
      end

      private def compile(schema, inherited_base, dialect, schema_path, resource_path, resource, document_key)
        dialect = dialect_for(schema, dialect)
        exclusive_ref = schema.is_a?(Hash) && schema.key?("$ref") && !dialect.ref_siblings?
        base = if schema.is_a?(Hash) && !exclusive_ref
          absolute_uri(inherited_base, schema["$id"])
        else
          inherited_base
        end
        base = inherited_base if base.empty?
        starts_resource = schema.is_a?(Hash) && schema.key?("$id") && !exclusive_ref &&
          !base.empty? && fragment(base).empty?
        resource_path = "" if starts_resource

        node = SchemaNode.new(
          schema: schema,
          dialect: dialect,
          base_uri: base,
          schema_path: schema_path,
          resource_path: resource_path,
          document_key: document_key
        )
        nodes << node
        @nodes_by_document_location[[document_key, schema_path]] = node

        if schema.is_a?(Hash) && schema.key?("$id") && !exclusive_ref && !base.empty?
          uri_registry[base] = node
          if starts_resource
            resource = register_resource(strip_fragment(base), node)
          end
        end

        resource ||= register_resource(strip_fragment(base), node)
        resource.add(node) unless node.resource

        dialect.each_subschema(schema) do |child_schema, segments|
          child_schema_path = append_segments(schema_path, segments)
          child_resource_path = append_segments(resource_path, segments)
          child = compile(
            child_schema,
            base,
            dialect,
            child_schema_path,
            child_resource_path,
            resource,
            document_key
          )
          node.add_child(segments, child)
        end
        node.freeze
      end

      private def register_resource(uri, root)
        resource = resources[uri]
        return resource if resource && resource.root.equal?(root)
        return resource if resource

        resources[uri] = Resource.new(uri, root)
      end

      private def index_external(document_uri)
        return if @indexed_external_schemas[document_uri]

        @indexed_external_schemas[document_uri] = true
        matches = @external_schemas.select do |external_uri, _schema|
          strip_fragment(external_uri.to_s) == document_uri
        end
        matches.each do |external_uri, external_schema|
          external_uri = external_uri.to_s
          dialect = dialect_for(external_schema, root.dialect)
          external_root = compile_document(external_schema, external_uri, dialect)
          uri_registry[external_uri] ||= external_root
        end
      end

      private def dialect_for(schema, fallback)
        return fallback unless schema.is_a?(Hash) && schema.key?("$schema")

        Dialect.resolve(schema["$schema"]) || fallback
      end

      private def absolute_uri(base, identifier)
        base = base.to_s
        return base if identifier.nil?

        identifier = identifier.to_s
        return identifier if base.empty? || identifier.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)
        return strip_fragment(base) if identifier.empty?
        return "#{strip_fragment(base)}#{identifier}" if identifier.start_with?("#")

        URI.join(base, identifier).to_s
      rescue URI::Error
        begin
          URI.join("resolve:///", base, identifier).to_s.delete_prefix("resolve:///")
        rescue URI::Error
          identifier
        end
      end

      private def strip_fragment(uri)
        index = uri.index("#")
        index ? uri[0, index] : uri
      end

      private def fragment(uri)
        index = uri.index("#")
        index ? uri[(index + 1)..] : ""
      end

      private def append_segments(path, segments)
        segments.reduce(path) do |result, segment|
          "#{result}/#{segment.to_s.gsub("~", "~0").gsub("/", "~1")}"
        end
      end

      private def canonical_pointer(pointer)
        return "" if pointer.empty?

        tokens = pointer.split("/", -1).drop(1).map do |token|
          decoded = token.gsub("~1", "/").gsub("~0", "~")
          decoded.gsub("~", "~0").gsub("/", "~1")
        end
        "/#{tokens.join("/")}"
      end

      private def pointer_target(document, pointer)
        pointer.split("/", -1).drop(1).reduce(document) do |current, token|
          key = token.gsub("~1", "/").gsub("~0", "~")
          if current.is_a?(Array)
            unless key.match?(/\A(?:0|[1-9]\d*)\z/)
              raise ResolutionError, "invalid JSON Pointer index #{key.inspect}"
            end
            current.fetch(key.to_i)
          elsif current.is_a?(Hash)
            current.fetch(key)
          else
            raise ResolutionError, "JSON Pointer traverses a scalar"
          end
        end
      rescue IndexError
        raise ResolutionError, "JSON Pointer target does not exist"
      end
    end
  end

  private_constant :Internal
end
