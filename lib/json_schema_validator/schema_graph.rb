# frozen_string_literal: true

require "uri"
require_relative "dialects/draft7"
require_relative "schema_node"

module JsonSchemaValidator
  module Internal
    class SchemaGraph
      class Resource
        attr_reader :uri, :root

        def initialize(uri, root)
          @uri = uri
          @root = root
          @nodes = nil
        end

        def add(node)
          (@nodes ||= {})[node.resource_path] = node unless node.equal?(root)
          node.resource = self
        end

        def node_at(pointer)
          return root if pointer.empty?

          @nodes&.[](pointer)
        end

        def nodes
          @nodes || EMPTY_NODES
        end

        EMPTY_NODES = {}.freeze
        private_constant :EMPTY_NODES
      end

      attr_reader :root, :resources, :uri_registry, :nodes

      def initialize(schema, schemas: {}, base_uri: nil, dialect: Dialect.resolve)
        @external_schemas = schemas
        @indexed_external_schemas = nil
        @resources = {}
        @uri_registry = {}
        @nodes = []
        @nodes_by_document_location = nil
        @resolved_refs = nil

        root_dialect = dialect_for(schema, dialect)
        @root = compile_document(schema, base_uri.to_s, root_dialect)
      end

      def resolve(node, reference)
        resolved_refs = (@resolved_refs ||= {})
        resolved = (resolved_refs[node] ||= {})
        return resolved[reference] if resolved.key?(reference)

        resolved[reference] = resolve_uncached(node, reference)
      end

      private def resolve_uncached(node, reference)
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
        if (target = node_by_document_location(resource.root.document_key, schema_path))
          return target
        end

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
        root = compile(schema, retrieval_uri, dialect, "", "", nil, retrieval_uri)
        document_uri = strip_fragment(retrieval_uri)
        register_resource(document_uri, root) unless resources.key?(document_uri)
        uri_registry[retrieval_uri] ||= root unless retrieval_uri.empty?
        uri_registry[document_uri] ||= root unless document_uri.empty?
        root
      end

      private def compile(schema, inherited_base, dialect, schema_path, resource_path, resource, document_key)
        hash_schema = schema.is_a?(Hash)
        dialect = dialect_for(schema, dialect) if hash_schema && schema.key?("$schema")
        exclusive_ref = hash_schema && schema.key?("$ref") && !dialect.ref_siblings?
        base = if hash_schema && !exclusive_ref && schema.key?("$id")
          absolute_uri(inherited_base, schema["$id"])
        else
          inherited_base
        end
        base = inherited_base if base.empty?
        starts_resource = hash_schema && schema.key?("$id") && !exclusive_ref &&
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
        if @nodes_by_document_location
          @nodes_by_document_location[[document_key, schema_path]] = node
        end

        if hash_schema && schema.key?("$id") && !exclusive_ref && !base.empty?
          uri_registry[base] = node
          if starts_resource
            resource = register_resource(strip_fragment(base), node)
          end
        end

        resource ||= register_resource(strip_fragment(base), node)
        resource.add(node) unless node.resource

        dialect.each_subschema(schema) do |child_schema, segments|
          child_schema_path = append_segments(schema_path, segments)
          child_resource_path = if resource_path == schema_path
            child_schema_path
          else
            append_segments(resource_path, segments)
          end
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

      private def node_by_document_location(document_key, schema_path)
        locations = (@nodes_by_document_location ||= nodes.to_h do |node|
          [[node.document_key, node.schema_path], node]
        end)
        locations[[document_key, schema_path]]
      end

      private def index_external(document_uri)
        indexed = (@indexed_external_schemas ||= {})
        return if indexed[document_uri]

        indexed[document_uri] = true
        if (dialect = Dialect.resolve(document_uri))
          compile_document(dialect.meta_schema, dialect.uri, dialect)
          return
        end
        if @external_schemas.key?(document_uri)
          external_schema = @external_schemas[document_uri]
          dialect = dialect_for(external_schema, root.dialect)
          compile_document(external_schema, document_uri, dialect)
          return
        end

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
          encoded = segment.to_s
          encoded = encoded.gsub("~", "~0") if encoded.include?("~")
          encoded = encoded.gsub("/", "~1") if encoded.include?("/")
          "#{result}/#{encoded}"
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
