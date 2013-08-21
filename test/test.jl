using Base.Test
using ZipFile

Debug = false

function findfile(dir, name)
	for f in dir.files
		if f.name == name
			return f
		end
	end
	None
end

function fileequals(f, s)
	readall(f) == s
end


# test a zip file created using Info-Zip
dir = ZipFile.Reader(joinpath(Pkg.dir("ZipFile"), "test/infozip.zip"))
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
]
# 2013-08-16	9:42:24
modtime = time(TmStruct(24, 42, 9, 16, 7, 2013-1900, 0, 0, -1))

dir = ZipFile.Writer("$tmp/hello.zip")
for (name, data, meth) in zipdata
	f = ZipFile.addfile(dir, name; method=meth, mtime=modtime)
	write(f, data)
end
close(dir)

dir = ZipFile.Reader("$tmp/hello.zip")
for (name, data, meth) in zipdata
	f = findfile(dir, name)
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
@test ascii(read(dir.files[1], Uint8, length(s1))) == s1
@test ascii(read(dir.files[1], Uint8, length(s2))) == s2
@test eof(dir.files[1])
close(dir)


data = {
    uint8(20),
    int(42),
    float(3.14),
    "julia",
    rand(5),
    rand(3, 4),
    sub(rand(10,10), 2:8,2:4),
}
filename = "$tmp/multi2.zip"
dir = ZipFile.Writer(filename)
f = ZipFile.addfile(dir, "data"; method=ZipFile.Deflate)
@test_throws read(f, Uint8, 1)
for x in data
    write(f, x)
end
close(dir)

dir = ZipFile.Reader(filename)
@test_throws write(dir.files[1], uint8(20))
for x in data
    if typeof(x) == ASCIIString
        @test x == ASCIIString(read(dir.files[1], Uint8, length(x)))
    elseif typeof(x) <: Array
        y = similar(x)
        y[:] = 0
        @test x == read(dir.files[1], y)
        @test x == y
    elseif typeof(x) <: SubArray
        continue # Base knows how to write, but not read
    else
        @test x == read(dir.files[1], typeof(x))
    end
end
close(dir)


if !Debug
	run(`rm -rf $tmp`)
end
