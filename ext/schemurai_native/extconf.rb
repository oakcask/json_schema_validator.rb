# frozen_string_literal: true

require "mkmf"

cflags = %w[-std=c99 -Wall -Wextra -Wno-unused-parameter]
cflags << "-Werror" if ENV["CI"]
append_cflags(cflags.join(" "))
create_makefile("schemurai_native")
