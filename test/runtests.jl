using Test
using ZipFile

Debug = false

@test Any[] == detect_ambiguities(Base, Core, ZipFile)

function findfile(dir, name)
    for f in dir.files
        if f.name == name
            return f
        end
    end
    nothing
end

function fileequals(f, s)
    read(f, String) == s
end


# test a zip file created using Info-Zip
dir = ZipFile.Reader(joinpath(dirname(@__FILE__), "infozip.zip"))
@test length(dir.files) == 4

f = findfile(dir, "ziptest/")
@test f.method == ZipFile.Store
@test f.uncompressedsize == 0
@test fileequals(f, "")

f = findfile(dir, "ziptest/hello.txt")
@test fileequals(f, "hello world!\n")

f = findfile(dir, "ziptest/info.txt")
@test fileequals(f, "Julia\nfor\ntechnical computing\n")

f = findfile(dir, "ziptest/julia.txt")
@test f.method == ZipFile.Deflate
@test fileequals(f, repeat("Julia\n", 10))

close(dir)


tmp = mktempdir()
if Debug
    println("temporary directory $tmp")
end

# write an empty zip file
dir = ZipFile.Writer("$tmp/empty.zip")
close(dir)
dir = ZipFile.Reader("$tmp/empty.zip")
@test length(dir.files) == 0


# write and then read back a zip file
zipdata = [
    ("hello.txt", "hello world!\n", ZipFile.Store),
    ("info.txt", "Julia\nfor\ntechnical computing\n", ZipFile.Store),
    ("julia.txt", "julia\n"^10, ZipFile.Deflate),
    ("empty1.txt", "", ZipFile.Store),
    ("empty2.txt", "", ZipFile.Deflate),
]
# 2013-08-16	9:42:24
modtime = time(Libc.TmStruct(24, 42, 9, 16, 7, 2013-1900, 0, 0, -1))

dir = ZipFile.Writer("$tmp/hello.zip")
@test length(string(dir)) > 0
for (name, data, meth) in zipdata
    local f = ZipFile.addfile(dir, name; method=meth, mtime=modtime)
    @test length(string(f)) > 0
    write(f, data)
end
close(dir)

dir = ZipFile.Reader("$tmp/hello.zip")
@test length(string(dir)) > 0
for (name, data, meth) in zipdata
    local f = findfile(dir, name)
    @test length(string(f)) > 0
    @test f.method == meth
    @test abs(mtime(f) - modtime) < 2
    @test fileequals(f, data)
end
close(dir)


s1 = "this is an example sentence"
s2 = ". hello world.\n"
filename = "$tmp/multi.zip"
dir = ZipFile.Writer(filename)
f = ZipFile.addfile(dir, "data"; method=ZipFile.Deflate)
write(f, s1)
write(f, s2)
close(dir)
dir = ZipFile.Reader(filename)
@test String(read!(dir.files[1], Array{UInt8}(undef, length(s1)))) == s1
@test String(read!(dir.files[1], Array{UInt8}(undef, length(s2)))) == s2
@test eof(dir.files[1])
close(dir)


data = Any[
    UInt8(20),
    Int(42),
    float(3.14),
    "julia",
    rand(5),
    rand(3, 4),
    view(rand(10,10), 2:8,2:4),
]
filename = "$tmp/multi2.zip"
dir = ZipFile.Writer(filename)
f = ZipFile.addfile(dir, "data"; method=ZipFile.Deflate)
@test_throws ErrorException read!(f, Array{UInt8}(undef, 1))
for x in data
    write(f, x)
end
close(dir)

dir = ZipFile.Reader(filename)
@test_throws ErrorException write(dir.files[1], UInt8(20))
for x in data
    if isa(x, String)
        @test x == String(read!(dir.files[1], Array{UInt8}(undef, length(x))))
    elseif isa(x, Array)
        y = similar(x)
        y[:] .= 0
        @test x == read!(dir.files[1], y)
        @test x == y
    elseif isa(x, SubArray)
        continue # Base knows how to write, but not read
    else
        @test x == read(dir.files[1], typeof(x))
    end
end
close(dir)


if !Debug
    rm(tmp, recursive=true)
end

println("done")
