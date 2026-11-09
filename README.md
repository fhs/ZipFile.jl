## Overview 

This module provides support for reading and writing ZIP archives in Julia.

[![Build Status](https://travis-ci.org/fhs/ZipFile.jl.png)](https://travis-ci.org/fhs/ZipFile.jl)

## Installation

Install via the Julia package manager, `Pkg.add("ZipFile")`.

## Documentation

Documentation is [available on JuliaHub](https://docs.juliahub.com/ZipFile/cOum2/0.10.0/).

Readers, writers, and new entries support `do` blocks:

```julia
using ZipFile

ZipFile.Writer("example.zip") do archive
    ZipFile.addfile(archive, "hello.txt"; method=ZipFile.Deflate) do entry
        write(entry, "hello world!\n")
    end
end

contents = ZipFile.Reader("example.zip") do archive
    read(archive.files[1], String)
end
```

Each form returns its callback's result and calls `close` in a `finally`
block, including when the callback throws. Existing `close` errors propagate
as usual. Passing your own `IO` to `Reader` or `Writer`
leaves that `IO` open. Closing an entry does not close the archive; adding
another entry still closes the previous one.
