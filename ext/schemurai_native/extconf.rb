# frozen_string_literal: true

require "mkmf"

append_cflags("-std=c99 -Wall -Wextra -Wno-unused-parameter")
create_makefile("schemurai_native")
