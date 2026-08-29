# frozen_string_literal: true

require_relative "../dialect_keywords"

module JsonSchemaValidator
  module Internal
    module Dialects
      module Draft202012
        META_SCHEMA_URI = "https://json-schema.org/draft/2020-12/schema"
        KEYWORDS = DialectKeywords.draft2020_12

        DIALECT = Dialect.new(
          name: :draft2020_12,
          uri: META_SCHEMA_URI,
          keywords: KEYWORDS,
          ref_siblings: true
        )

        Dialect.register(DIALECT)

        private_constant :META_SCHEMA_URI, :KEYWORDS
      end
    end
  end

  private_constant :Internal
end
