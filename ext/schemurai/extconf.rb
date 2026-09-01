# frozen_string_literal: true

require "mkmf"

abort "schemurai native extension requires CRuby" unless RUBY_ENGINE == "ruby"

append_cflags("-std=c99 -Wall -Wextra -Werror=implicit-function-declaration")
create_makefile("schemurai/schemurai_native")
