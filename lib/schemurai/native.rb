# frozen_string_literal: true

begin
  require "schemurai/schemurai_native"
rescue LoadError => installed_error
  begin
    require "schemurai_native"
  rescue LoadError
    raise installed_error
  end
end

unless Schemurai::Native::BACKEND == :native && Schemurai::Native.const_defined?(:Evaluator, false)
  raise LoadError, "native extension did not provide the native evaluator"
end
