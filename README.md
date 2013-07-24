## Overview 

This module provides support for reading and writing ZIP archives in Julia.

## Installation

Install via the Julia package manager, `Pkg.add("ZipFile")`.

## Example usage

Write a new ZIP file:

```julia
using ZipFile

dir = ZipFile.open("example.zip", true);
f = ZipFile.addfile(dir, "hello.txt");
write(f, "hello world!\n");
f = ZipFile.addfile(dir, "julia.txt", method=ZipFile.Deflate);
write(f, "Julia\n"^5);
close(dir)
```

Read and print out the contents of a ZIP file:

```julia
dir = ZipFile.open("example.zip");
for f in dir.files
	println("Filename: $(f.name)")
	write(readall(f));
end
close(dir)
```
Output:

```
Filename: hello.txt
hello world!
Filename: julia.txt
Julia
Julia
Julia
Julia
Julia
```
