# frozen_string_literal: true

module Schemurai
  module Backend
    NATIVE_FEATURE = "schemurai/native"
    CHOICES = %i[default ruby native].freeze
    PRODUCTION_DEFAULT = :ruby

    module_function def requested
      value = ENV.fetch("SCHEMURAI_BACKEND", "default").to_sym
      return value if CHOICES.include?(value)

      raise Error, "unknown Schemurai backend #{value.inspect}"
    end

    module_function def resolve(selection = requested)
      selection = selection.to_sym
      raise Error, "unknown Schemurai backend #{selection.inspect}" unless CHOICES.include?(selection)

      selection = production_default if selection == :default
      load_native! if selection == :native
      selection
    end

    module_function def production_default
      PRODUCTION_DEFAULT
    end

    module_function def native_available?
      return false if native_loading_prohibited?

      load_native!
      true
    rescue LoadError
      false
    end

    module_function def load_native!
      if native_loading_prohibited?
        raise LoadError, "native backend loading is prohibited by SCHEMURAI_NATIVE_LOADING"
      end

      require NATIVE_FEATURE
      unless Schemurai::Native.const_defined?(:Validator, false)
        raise LoadError, "native bootstrap is available but validation dispatch is not implemented"
      end
    rescue LoadError => error
      raise LoadError, "native backend is unavailable: #{error.message}"
    end

    module_function def native_loading_prohibited?
      ENV["SCHEMURAI_NATIVE_LOADING"] == "prohibited"
    end
  end
end
