# frozen_string_literal: true

require "schemurai"
require "schemurai/native"

abort "expected the packaged native bootstrap" unless Schemurai::Native::BACKEND == :native
abort "expected the generated boolean intrinsic" unless Schemurai::Native::Intrinsics.boolean_instance?(true)
abort "expected packaged native type validation" unless Schemurai.valid?({"type" => "integer"}, 42, backend: :native)
abort "expected strict native type validation" if Schemurai.valid?({"type" => "integer"}, 4.2, backend: :native)
native_validator = Schemurai.compile(
  {
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "$id" => "urn:package:root",
    "type" => "integer",
    "$defs" => {"nested" => {"type" => "string"}}
  },
  backend: :native
)
native_graph = native_validator.instance_variable_get(:@evaluator).instance_variable_get(:@graph)
abort "expected packaged native graph compilation" unless native_graph.node_count == 2
abort "expected packaged native graph URI lookup" unless native_graph.lookup("urn:package:root") == native_graph.root_index

schema = {
  "$schema" => "https://json-schema.org/draft/2020-12/schema",
  "type" => "object",
  "properties" => {
    "order_id" => {"type" => "string", "pattern" => "^ord_[0-9]{6}$"},
    "customer" => {"$ref" => "#/$defs/customer"},
    "items" => {
      "type" => "array",
      "minItems" => 1,
      "items" => {"$ref" => "#/$defs/line_item"}
    },
    "created_at" => {"type" => "string", "format" => "date-time"}
  },
  "required" => %w[order_id customer items created_at],
  "additionalProperties" => false,
  "$defs" => {
    "customer" => {
      "type" => "object",
      "properties" => {
        "id" => {"type" => "integer", "minimum" => 1},
        "name" => {"type" => "string", "minLength" => 1},
        "tier" => {"enum" => %w[standard premium]}
      },
      "required" => %w[id name],
      "additionalProperties" => false
    },
    "line_item" => {
      "type" => "object",
      "properties" => {
        "sku" => {"type" => "string", "pattern" => "^SKU-[A-Z0-9]{8}$"},
        "quantity" => {"type" => "integer", "minimum" => 1},
        "unit_price" => {"type" => "number", "minimum" => 0}
      },
      "required" => %w[sku quantity unit_price],
      "additionalProperties" => false
    }
  }
}

order = {
  "order_id" => "ord_123456",
  "customer" => {"id" => 42, "name" => "Ada Lovelace", "tier" => "premium"},
  "items" => [
    {"sku" => "SKU-ABC12345", "quantity" => 2, "unit_price" => 19.95}
  ],
  "created_at" => "2026-08-31T10:15:00+09:00"
}

validator = Schemurai.compile(schema, format: true, backend: :native)
abort "expected the order to be valid" unless validator.valid?(order)

invalid_order = order.merge(
  "items" => [order.fetch("items").first.merge("quantity" => 0)]
)
result = validator.validate(invalid_order)
quantity_error = result.errors.any? do |error|
  error.keyword == "minimum" && error.instance_path == "/items/0/quantity"
end
abort "expected an invalid quantity error" unless quantity_error

puts "Installed gem validated the sample order"
