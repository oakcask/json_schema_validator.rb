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
      return self if other.evaluated_properties.empty? && other.evaluated_items.empty?
      return other if evaluated_properties.empty? && evaluated_items.empty?

      properties = if evaluated_properties.empty?
        other.evaluated_properties
      elsif other.evaluated_properties.empty?
        evaluated_properties
      else
        evaluated_properties | other.evaluated_properties
      end
      items = if evaluated_items.empty?
        other.evaluated_items
      elsif other.evaluated_items.empty?
        evaluated_items
      else
        evaluated_items | other.evaluated_items
      end

      self.class.valid(
        evaluated_properties: properties,
        evaluated_items: items
      )
    end
  end

  private_constant :Evaluation
end
