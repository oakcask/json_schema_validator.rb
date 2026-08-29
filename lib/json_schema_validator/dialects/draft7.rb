# frozen_string_literal: true

require_relative "../dialect_keywords"

module JsonSchemaValidator
  module Internal
    module Dialects
      module Draft7
        META_SCHEMA_URI = "http://json-schema.org/draft-07/schema"
        KEYWORDS = DialectKeywords.draft7

        DIALECT = Dialect.new(
          name: :draft7,
          uri: META_SCHEMA_URI,
          keywords: KEYWORDS,
          ref_siblings: false
        )

        Dialect.register(DIALECT, default: true)

        private_constant :META_SCHEMA_URI, :KEYWORDS
      end
    end
  end

  private_constant :Internal
end
