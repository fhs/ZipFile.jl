
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

dir = zipopen("ziptest.zip")
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
