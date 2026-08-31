# frozen_string_literal: true

module Schemurai
  module Internal
    module SchemaDomain
      module_function def validate!(schema, label: "schema")
        unless schema.equal?(true) || schema.equal?(false) || schema.instance_of?(Hash)
          invalid!(label, "must be a boolean or an object")
        end

        validate_value!(schema, label, {})
        schema
      end

      module_function def validate_registry!(schemas)
        invalid!("schemas", "must be an object") unless schemas.instance_of?(Hash)

        schemas.each do |uri, schema|
          invalid!("schemas", "contains a non-string URI key") unless uri.instance_of?(String)

          validate!(schema, label: "schemas[#{uri.inspect}]")
        end
        schemas
      end

      module_function def validate_value!(value, path, ancestors)
        case value
        when nil, true, false
          nil
        when String, Integer
          invalid!(path, "uses a subclass of #{value.class.superclass}") unless supported_exact_scalar?(value)
        when Float
          invalid!(path, "must contain only finite numbers") unless value.finite?
          invalid!(path, "uses a Float subclass") unless value.instance_of?(Float)
        when Array
          invalid!(path, "uses an Array subclass") unless value.instance_of?(Array)
          descend!(value, path, ancestors) do
            value.each_with_index { |item, index| validate_value!(item, pointer(path, index), ancestors) }
          end
        when Hash
          invalid!(path, "uses a Hash subclass") unless value.instance_of?(Hash)
          descend!(value, path, ancestors) do
            value.each do |key, item|
              invalid!(path, "contains a non-string object key") unless key.instance_of?(String)

              validate_value!(item, pointer(path, key), ancestors)
            end
          end
        else
          invalid!(path, "contains unsupported #{value.class}")
        end
      end
      private_class_method :validate_value!

      module_function def supported_exact_scalar?(value)
        value.instance_of?(String) || value.instance_of?(Integer)
      end
      private_class_method :supported_exact_scalar?

      module_function def descend!(value, path, ancestors)
        invalid!(path, "contains a recursive container") if ancestors.key?(value.object_id)

        ancestors[value.object_id] = true
        yield
      ensure
        ancestors.delete(value.object_id)
      end
      private_class_method :descend!

      module_function def pointer(path, segment)
        escaped = segment.to_s.gsub("~", "~0").gsub("/", "~1")
        "#{path}/#{escaped}"
      end
      private_class_method :pointer

      module_function def invalid!(path, reason)
        raise Error, "invalid JSON-shaped #{path}: #{reason}"
      end
      private_class_method :invalid!
    end
  end
end
