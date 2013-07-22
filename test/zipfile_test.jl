using Base.Test
using ZipFile

function findfile(dir, name)
	for f in dir.files
		if f.name == name
			return f
		end
	end
	None
end

function fileequals(f, s)
	readall(f) == convert(Vector{Uint8}, s)
end


# test a zip file created using Info-Zip
dir = ZipFile.open("ziptest.zip")
@test length(dir.files) == 4

f = findfile(dir, "ziptest/")
@test f.compression == ZipFile.Store
@test f.uncompressedsize == 0
@test fileequals(f, "")

f = findfile(dir, "ziptest/hello.txt")
@test fileequals(f, "hello world!\n")

f = findfile(dir, "ziptest/info.txt")
@test fileequals(f, "Julia\nfor\ntechnical computing\n")

f = findfile(dir, "ziptest/julia.txt")
@test f.compression == ZipFile.Deflate
@test fileequals(f, repeat("Julia\n", 10))

close(dir)

tmp = mktempdir()
println("temporary directory: $tmp")

# write an empty zip file
dir = ZipFile.open("$tmp/empty.zip", true)
close(dir)
dir = ZipFile.open("$tmp/empty.zip")
@test length(dir.files) == 0


# write and then read back a zip file
zipdata = [
	("hello.txt", "hello world!\n", ZipFile.Store),
	("info.txt", "Julia\nfor\ntechnical computing\n", ZipFile.Store),
	("julia.txt", "julia\n"^10, ZipFile.Deflate),
]

dir = ZipFile.open("$tmp/hello.zip", true)
for (name, data, comp) in zipdata
	f = ZipFile.addfile(dir, name, compression=comp)
	write(f, data)
end
close(dir)

dir = ZipFile.open("$tmp/hello.zip")
for (name, data, comp) in zipdata
	f = findfile(dir, name)
	@test f.compression == comp
	@test fileequals(f, data)
end
close(dir)

run(`rm -rf $tmp`)
