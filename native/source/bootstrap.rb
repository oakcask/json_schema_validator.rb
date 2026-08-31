# frozen_string_literal: true

module Schemurai
  module NativeSource
    def self.boolean_instance?(instance)
      true.equal?(instance) || false.equal?(instance)
    end
  end
end
