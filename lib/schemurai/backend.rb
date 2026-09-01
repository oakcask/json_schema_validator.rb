# frozen_string_literal: true

module Schemurai
  module Backend
    BYTECODE_FEATURE = "bytecode/evaluator"
    CHOICES = %i[default ruby bytecode].freeze

    module_function def requested
      value = ENV.fetch("SCHEMURAI_BACKEND", "default").to_sym
      return value if CHOICES.include?(value)

      raise Error, "unknown Schemurai backend #{value.inspect}"
    end

    module_function def resolve(selection = requested)
      selection = selection.to_sym
      raise Error, "unknown Schemurai backend #{selection.inspect}" unless CHOICES.include?(selection)

      selection = production_default if selection == :default
      load_bytecode! if selection == :bytecode
      selection
    end

    module_function def production_default
      :ruby
    end

    module_function def load_bytecode!
      require_relative BYTECODE_FEATURE
    end
  end
end
