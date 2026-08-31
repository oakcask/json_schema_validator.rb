# frozen_string_literal: true

require_relative "../dialect_keywords"

module Schemurai
  module Internal
    module Dialects
      module Draft201909
        META_SCHEMA_URI = "https://json-schema.org/draft/2019-09/schema"
        KEYWORDS = DialectKeywords.draft2019_09

        DIALECT = Dialect.new(
          name: :draft2019_09,
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
