ZipFile.jl: Read/Write ZIP file archives in Julia
=================================================

This module provides support for reading and writing ZIP archives.

Example usage
-------------

Write a new ZIP file:

```julia
julia> using ZipFile

julia> dir = ZipFile.open("example.zip", true);

julia> f = ZipFile.addfile(dir, "hello.txt");

julia> write(f, "hello world!\n");

julia> f = ZipFile.addfile(dir, "julia.txt", method=ZipFile.Deflate);

julia> write(f, "Julia\n"^5);

julia> close(dir)
```

Read and print out the contents of a ZIP file:

```julia
julia> dir = ZipFile.open("example.zip");

julia> for f in dir.files
           println("Filename: $(f.name)")
           write(utf8(readall(f)));
       end
Filename: hello.txt
hello world!
Filename: julia.txt
Julia
Julia
Julia
Julia
Julia

julia> close(dir)
```
