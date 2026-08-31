# frozen_string_literal: true

require "mkmf"

abort "schemurai native extension requires CRuby 4.0" unless RUBY_ENGINE == "ruby" && RUBY_VERSION.match?(/\A4\.0\./)

append_cflags("-std=c99 -Wall -Wextra -Werror=implicit-function-declaration")
create_makefile("schemurai/schemurai_native")
