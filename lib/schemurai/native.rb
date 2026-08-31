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

unless Schemurai::Native::BACKEND == :native
  raise LoadError, "native extension reported an invalid backend identity"
end
