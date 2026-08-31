# frozen_string_literal: true

module Schemurai
  # Internal result of evaluating one schema location. Draft 7 only needs the
  # validity bit, but newer drafts also propagate the instance locations
  # consumed by applicators for unevaluatedProperties and unevaluatedItems.
  class Evaluation
    EMPTY_LOCATIONS = [].freeze

    attr_reader :evaluated_properties, :evaluated_items

    def self.valid(evaluated_properties: EMPTY_LOCATIONS, evaluated_items: EMPTY_LOCATIONS)
      if evaluated_properties.equal?(EMPTY_LOCATIONS) && evaluated_items.equal?(EMPTY_LOCATIONS)
        return @valid ||= new(true, EMPTY_LOCATIONS, EMPTY_LOCATIONS)
      end

      new(true, evaluated_properties, evaluated_items)
    end

    def self.invalid
      @invalid ||= new(false, EMPTY_LOCATIONS, EMPTY_LOCATIONS)
    end

    def initialize(valid, evaluated_properties, evaluated_items)
      @valid = valid
      @evaluated_properties = evaluated_properties.freeze
      @evaluated_items = evaluated_items.freeze
      freeze
    end

    def valid?
      @valid
    end

    def merge(other)
      return self.class.invalid unless valid? && other.valid?

      self.class.valid(
        evaluated_properties: (evaluated_properties | other.evaluated_properties),
        evaluated_items: (evaluated_items | other.evaluated_items)
      )
    end
  end

  private_constant :Evaluation
end
