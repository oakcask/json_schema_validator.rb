# frozen_string_literal: true

module Schemurai
  module Internal
    module MetaSchemas
      class << self
        def register(uri, schema)
          registry[normalize_uri(uri)] = schema
          schema
        end

        def resolve(uri)
          registry[normalize_uri(uri)]
        end

        private def registry
          @registry ||= {}
        end

        private def normalize_uri(uri)
          uri.to_s.delete_suffix("#")
        end
      end
    end
  end

  private_constant :Internal
end
