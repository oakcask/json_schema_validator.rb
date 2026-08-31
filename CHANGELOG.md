# Changelog

## 1.0.0 (2026-08-31)


### ⚠ BREAKING CHANGES

* replace require "json_schema_validator" with require "schemurai" and replace JsonSchemaValidator references with Schemurai.
* compile now returns Validator instead of CompiledSchema, Validator construction no longer accepts CompiledSchema, and compile keyword-schema shorthand is removed.
* `JsonSchemaValidator::Error` is now the base exception. Validation result entries previously represented by that data type are now `JsonSchemaValidator::ValidationError`.

### Features

* add draft 7 implementation and benchmark ([4f4423f](https://github.com/oakcask/schemurai/commit/4f4423fb90b285b8e838fc6ddcbc5cfd85c1eedd))
* add shareable schema registries ([#35](https://github.com/oakcask/schemurai/issues/35)) ([485f895](https://github.com/oakcask/schemurai/commit/485f89521d289729790e2aed0ee1aca7787be880))
* enable IPv4 format validation tests ([#19](https://github.com/oakcask/schemurai/issues/19)) ([3d88aef](https://github.com/oakcask/schemurai/commit/3d88aef3dfaeada000879435f512ea070451d542))
* implement duration, UUID, and JSON Pointer formats ([#20](https://github.com/oakcask/schemurai/issues/20)) ([8a25578](https://github.com/oakcask/schemurai/commit/8a25578a3aac78f0882af3bd99bcb43641e30bd3))
* share compiled schema registries across validators ([#10](https://github.com/oakcask/schemurai/issues/10)) ([59497ae](https://github.com/oakcask/schemurai/commit/59497ae55c3fd6a9140b3eddd9e58a2cc23b78f5))
* support draft 2019-09 and 2020-12 ([#9](https://github.com/oakcask/schemurai/issues/9)) ([d0fc395](https://github.com/oakcask/schemurai/commit/d0fc395da72273a63cd031368c995f9a8e22042b))
* support IPv6 format validation ([#27](https://github.com/oakcask/schemurai/issues/27)) ([b962495](https://github.com/oakcask/schemurai/commit/b962495944484922eda300552b3f2c9f314c4267))
* validate RFC 3339 date and time formats ([#18](https://github.com/oakcask/schemurai/issues/18)) ([aed0571](https://github.com/oakcask/schemurai/commit/aed057188208e0699e9f01333b2a92557bfe657c))


### Bug Fixes

* keep constants private ([#4](https://github.com/oakcask/schemurai/issues/4)) ([48c0f44](https://github.com/oakcask/schemurai/commit/48c0f4460348166ef9f22f7d635b64a07a3a7239))
* keep SchemaGraph unchanged after compile errors ([#31](https://github.com/oakcask/schemurai/issues/31)) ([7e3b4b1](https://github.com/oakcask/schemurai/commit/7e3b4b103e894b2b5233795b194e04a5c2585e73))
* reject unsupported assertion formats ([#21](https://github.com/oakcask/schemurai/issues/21)) ([43a0ea0](https://github.com/oakcask/schemurai/commit/43a0ea01b5b2e550c7bcf120f975dcf81b83e761))
* resolve RuboCop leaky local variables ([#33](https://github.com/oakcask/schemurai/issues/33)) ([7cf73f9](https://github.com/oakcask/schemurai/commit/7cf73f90a3fd32776db403ffa5904e99ce99c105))


### Performance Improvements

* avoid URI.join if unecessary ([eaefbb7](https://github.com/oakcask/schemurai/commit/eaefbb7913fe481ba640f940e4caec7d0e9e557e))
* cache external documents ([39b6e28](https://github.com/oakcask/schemurai/commit/39b6e28650e9ae2ca3e9a4e7b0b30c9210ee28ee))
* defer validation error pointer generation ([#43](https://github.com/oakcask/schemurai/issues/43)) ([552abd9](https://github.com/oakcask/schemurai/commit/552abd944ec7091d3e042fabbe50ee1ece400bea))
* improve performance ([4faafab](https://github.com/oakcask/schemurai/commit/4faafab4f0e7620d2e2311452d5f22ce7ef845bd))
* reduce object allocations ([#2](https://github.com/oakcask/schemurai/issues/2)) ([8566619](https://github.com/oakcask/schemurai/commit/8566619022756b7cf53d11ce8b84678df43187c2))
* skip unused dynamic scope tracking ([#12](https://github.com/oakcask/schemurai/issues/12)) ([f576d59](https://github.com/oakcask/schemurai/commit/f576d59a563c7f186b124a04a0da0b0ec8e1ed21))
* use nested hash for schema children ([#15](https://github.com/oakcask/schemurai/issues/15)) ([23e392a](https://github.com/oakcask/schemurai/commit/23e392ad72cdcebe91b7460500646cd98aa6e328))
* use nested hashes for schema graph indexes ([#26](https://github.com/oakcask/schemurai/issues/26)) ([6426dd4](https://github.com/oakcask/schemurai/commit/6426dd476dddb58068378b3d5adb575fbc45e213))


### Code Refactoring

* rename gem to schemurai ([#37](https://github.com/oakcask/schemurai/issues/37)) ([8ca2751](https://github.com/oakcask/schemurai/commit/8ca2751ee33d45012fa46859ec67bb85c3bd228b))
* return validators from compile ([#32](https://github.com/oakcask/schemurai/issues/32)) ([5a24430](https://github.com/oakcask/schemurai/commit/5a244309f027bddea3c17b9a43432cde8a8d90fe))
