an example implementation to format nvim buffers

## features
* keep cursor stay where it was during formatting
* use diff+patch to update the buffer
* rate limit
* profiles of formatters

## design choices
* only for files of source code
* no communicating with external formatting program
* run runners by order, crashing wont make original buffer dirty
* suppose all external formatting program do inplace

## status
* it just works(tm)
* it uses ffi which may crash nvim
* no more formatters are planned

## prerequisites
* linux
* nvim 0.9.*
* haolian9/infra.nvim
* haolian9/cthulhu.nvim

