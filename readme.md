an example implementation to format nvim buffers

## features
* keep cursor where it was during formatting among windows
* use diff+patch to update the buffer
* rate limit
* profiles of formatters

## design choices
* only for source files
* no communicating with external formatting programs
* run runners by order, crashing should not make the original buffer dirty
* suppose all external formatting programs format inplace

## status
* it just works(tm)
* it uses ffi which may crash nvim
* no more formatters are planned

## prerequisites
* linux
* nvim 0.9.*
* haolian9/infra.nvim
* haolian9/cthulhu.nvim

