## Overview 

This module provides support for reading and writing ZIP archives in Julia.

[![Build Status](https://travis-ci.org/fhs/ZipFile.jl.png)](https://travis-ci.org/fhs/ZipFile.jl)

## Installation

Install via the Julia package manager, `Pkg.add("ZipFile")`.


## High level interface

Use `open_zip` to read/write to/from a ZIP Archive.

Use `create_zip` to create a new ZIP Archive in one step.

ZIP Archives can be read and created via:

 - filenames,
 - `Base.IO` streams, or
 - `Array{UInt8,1}`.


## open_zip

The result of `open_zip(archive)` is iterable and can be accessed as an Associative collection.

```julia
# Print size of each file in "foo.zip"...
for (filename, data) in open_zip("foo.zip")
    println("$filename has $(length(data)) bytes")
end


# Read contents of "bar.csv" from "foo.zip"...
data = open_zip("foo.zip")["foo/bar.csv"]


# Read "foo.zip" from in-memory ZIP archive...
zip_data = http_get("http://foo.com/foo.zip")
data = open_zip(zip_data)["bar.csv"]


# Create a Dict from a ZIP archive...
Dict(open_zip("foo.zip"))
Dict{AbstractString,Any} with 2 entries:
  "hello.txt"    => "Hello!\n"
  "foo/text.txt" => "text\n"


# Create "foo.zip" with two files...
open_zip("foo.zip", "w") do z
    z["hello.txt"] = "Hello!\n"
    z["bar.csv"] = "1,2,3\n"
end


# Create in-memory ZIP archive in "buf"...
buf = UInt8[]
open_zip(buf) do z
    z["hello.txt"] = "Hello!\n"
    z["bar.csv"] = "1,2,3\n"
end
http_put("http://foo.com/foo.zip", buf)


# Add a new file to an existing archive"...
open_zip("foo.zip", "r+") do z
    z["newfile.csv"] = "1,2,3\n"
end


# Update an existing file in an archive"...
open_zip("foo.zip", "r+") do z
    z["newfile.csv"] = lowercase(z["newfile.csv"])
end

```


## create_zip

`create_zip([destination], content)` creates a ZIP archive from "content' in a single step. If "destination" is omitted the archive is returned as `Array{UInt8}`.

```julia

# Create archive from Dict...
create_zip("foo.zip", Dict("hello.txt" => "Hello!\n",
                           "bar.csv" => "1,2,3\n"))


# Create archive from Pairs...
create_zip(io, "hello.txt" => "Hello!\n",
               "bar.csv" => "1,2,3\n"))


# Create archive from Tuples...
zip_data = create_zip(io, [("hello.txt", "Hello!\n"),
                           ("bar.csv" => "1,2,3\n")])


# Create archive from filenames array and data array...
zip_data = create_zip(io, ["hello.txt", "bar.csv"],
                          ["Hello!\n",  "1,2,3\n"])
```


## unzip

`unzip(archive, [outputdir])` extracts an archive to files in "outputdir" (or in the current directory by default).

```julia
unzip("foo.zip", "/tmp/")

unzip(http_get("http://foo.com/foo.zip", "/tmp/"))
```

*Based on [fhs/ZipFile.jl#16](https://github.com/fhs/ZipFile.jl/pull/16), thanks @timholy*


## Low level interface

The low level interface provides incremental read/write, timestamps, etc.

See https://zipfilejl.readthedocs.org/en/latest/
