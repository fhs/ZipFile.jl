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

tmp = mktempdir()

# write an empty zip file
dir = zipopen("$tmp/empty.zip", true)
close(dir)
dir = zipopen("$tmp/empty.zip")
@test length(dir.files) == 0


# write and then read back a zip file
zipdata = [
	("hello.txt", "hello world!\n"),
	("info.txt", "Julia\nfor\ntechnical computing\n"),
	("julia.txt", "julia\n"^10),
]

dir = zipopen("$tmp/hello.zip", true)
for (name, data) in zipdata
	f = ZipFile.newfile(dir, name)
	write(f, data)
end
close(dir)

dir = zipopen("$tmp/hello.zip")
for (name, data) in zipdata
	@test fileequals(findfile(dir, name), data)
end
close(dir)

run(`rm -rf $tmp`)
