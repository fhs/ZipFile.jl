## Overview 

This module provides support for reading and writing ZIP archives in Julia.

[![Build Status](https://travis-ci.org/fhs/ZipFile.jl.png)](https://travis-ci.org/fhs/ZipFile.jl)

## Installation

## Usage 
Install via the Julia package manager, `Pkg.add("ZipFile")`.

A Julia package for reading/writing ZIP archive files

This package provides support for reading and writing ZIP archives in Julia.
Install it via the Julia package manager using ``Pkg.add("ZipFile")``.

The ZIP file format is described in
http://www.pkware.com/documents/casestudies/APPNOTE.TXT

### Example
The example below writes a new ZIP file and then reads back the contents.
```julia
julia> using ZipFile
julia> w = ZipFile.Writer("/tmp/example.zip");
julia> f = ZipFile.addfile(w, "hello.txt");
julia> write(f, "hello world!\n");
julia> f = ZipFile.addfile(w, "julia.txt", method=ZipFile.Deflate);
julia> write(f, "Julia\n"^5);
julia> close(w)
julia> r = ZipFile.Reader("/tmp/example.zip");
julia> for f in r.files
          println("Filename: \$(f.name)")
          write(stdout, read(f, String));
       end
julia> close(r)
Filename: hello.txt
hello world!
Filename: julia.txt
Julia
Julia
Julia
Julia
Julia
```