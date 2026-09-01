# Ruby oracle compatibility domain

This document freezes the observable Ruby behavior that alternate evaluator
backends must match. The machine-readable companion is
`oracle/compatibility_cases.json`.

## Schema inputs

A schema root is exactly `true`, `false`, or a built-in `Hash`. Every retained
value must recursively be a built-in `Hash`, `Array`, `String`, `Integer`, a
finite built-in `Float`, `true`, `false`, or `nil`; object keys must be built-in
`String` instances. Recursive containers, non-finite floats, subclasses, and
all other Ruby objects are rejected with `Schemurai::Error` before a schema
graph is mutated or retains the value. Registry URI keys must be built-in
strings, and registered external schemas follow the same rule.

Caller-owned accepted schema objects are retained, not copied. Calling
`SchemaRegistry#make_shareable` therefore freezes those objects in place as
part of `Ractor.make_shareable`.

## Instance inputs

The supported JSON-shaped instance domain consists recursively of built-in
`Hash` and `Array` containers with built-in string keys, and the scalar classes
`String`, `Integer`, finite `Float`, `TrueClass`, `FalseClass`, and `NilClass`.
Integers have arbitrary precision. JSON Schema `number` and `integer` semantics
within this domain cover `Integer` and finite `Float`; an integral finite float
is an integer for the `type` keyword. `NaN`, infinities, `Rational`, `Complex`,
`BigDecimal`, other `Numeric` implementations, and subclasses of supported
classes are outside the supported domain.

The Ruby evaluator currently has observable behavior for selected values
outside this domain. The fixtures explicitly freeze that behavior for core
subclasses, singleton overrides, coercible numeric objects, mutation during
iteration, and exceptional numeric methods. Backend specialization may use a
cold compatibility branch for those named fixtures, but no other behavior of
arbitrary Ruby objects, monkey patches, or refinements is promised.

## Observable results

Compatibility includes the `valid?` boolean, `Schemurai::ValidationError`
class, detailed error keyword, instance path, schema path, error order, and the
presence of a String message. Exact validation message wording is not part of
the compatibility contract. Programmatic consumers must use the keyword and
paths instead. Compatibility also includes the class and message of exceptions
named by compatibility fixtures, registry state and mutation rejection, and
validator use from threads and Ractors. The oracle runner preserves error order
and records backend identity so comparison cannot hide a Ruby fallback; the
comparator normalizes validation message text while retaining its presence and
type.
