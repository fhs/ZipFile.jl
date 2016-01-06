using Base.Test
using Compat
using ZipFile

Debug = false

function findfile(dir, name)
	for f in dir.files
		if f.name == name
			return f
		end
	end
	nothing
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
modtime = time(@compat(Libc.TmStruct(24, 42, 9, 16, 7, 2013-1900, 0, 0, -1)))

dir = ZipFile.Writer("$tmp/hello.zip")
@test length(string(dir)) > 0
for (name, data, meth) in zipdata
	f = ZipFile.addfile(dir, name; method=meth, mtime=modtime)
	@test length(string(f)) > 0
	write(f, data)
end
close(dir)

dir = ZipFile.Reader("$tmp/hello.zip")
@test length(string(dir)) > 0
for (name, data, meth) in zipdata
	f = findfile(dir, name)
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
@test ascii(read(dir.files[1], @compat(UInt8), length(s1))) == s1
@test ascii(read(dir.files[1], @compat(UInt8), length(s2))) == s2
@test eof(dir.files[1])
close(dir)


data = Any[
    @compat(UInt8(20)),
    @compat(Int(42)),
    float(3.14),
    "julia",
    rand(5),
    rand(3, 4),
    sub(rand(10,10), 2:8,2:4),
]
filename = "$tmp/multi2.zip"
dir = ZipFile.Writer(filename)
f = ZipFile.addfile(dir, "data"; method=ZipFile.Deflate)
@test_throws ErrorException read(f, @compat(UInt8), 1)
for x in data
    write(f, x)
end
close(dir)

dir = ZipFile.Reader(filename)
@test_throws ErrorException write(dir.files[1], @compat(UInt8(20)))
for x in data
    if typeof(x) == ASCIIString
        @test x == ASCIIString(read(dir.files[1], @compat(UInt8), length(x)))
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


# Command line "unzip" interface.

function unzip_tool_is_missing()
    try
        readall(`unzip`)
        return false
    catch
        println("WARNING: unzip tool not found!")
        return true
    end
end

# Unzip file to dict using external "unzip" tool.

function test_unzip_file(z)
    r = Dict()
    for f in readlines(`unzip -Z1 $z`)
        f = chomp(f)
        r[f] = readall(`unzip -qc $z $f`)
    end
    return r
end


# Unzip zip data to dict using external "unzip" tool.

function test_unzip(zip)
    mktemp((tmp,io)-> begin
        write(io, zip)
        close(io)
        return test_unzip_file(tmp)
    end)
end


dict = Dict("hello.txt"     => "Hello!\n",
            "foo/text.txt"  => "text\n")

# In memory ZIP from Dict...
@test dict == test_unzip(create_zip(dict))

@test dict == Dict(open_zip(create_zip(dict)))

@test open_zip(create_zip(dict))["hello.txt"] == "Hello!\n"

@test open_zip(create_zip("empty" => ""))["empty"] == ""

# In memory ZIP from pairs...
@test dict == test_unzip(create_zip("hello.txt"     => "Hello!\n",
                                   "foo/text.txt"  => "text\n"))

# In memory ZIP from tuples...
@test dict == test_unzip(create_zip(("hello.txt",     "Hello!\n"),
                                    ("foo/text.txt",  "text\n")))

# In memory ZIP from tuples...
@test dict == test_unzip(create_zip([("hello.txt",     "Hello!\n"),
                                    ("foo/text.txt",  "text\n")]))

# In memory ZIP from arrays...
@test dict == test_unzip(create_zip(["hello.txt", "foo/text.txt"],
                                    ["Hello!\n", "text\n"]))

# In memory ZIP using "do"...
zip_data = UInt8[]
open_zip(zip_data) do z
    z["hello.txt"] = "Hello!\n"
    z["foo/text.txt"] = "text\n"
end
@test dict == Dict(open_zip(zip_data))
 

# ZIP to file from Dict...
unzip_dict = ""
z = tempname()
#try
    create_zip(z, dict)

    @test unzip_tool_is_missing() || dict == test_unzip_file(z)

    @test open_zip(z)["hello.txt"] == "Hello!\n"

    @test dict == Dict(open_zip(z))

#finally
#    rm(z)
##end


# ZIP to file from Pairs...
unzip_dict = ""
z = tempname()
try
    create_zip(z, "hello.txt"     => "Hello!\n",
                  "foo/text.txt"  => "text\n")
    @test unzip_tool_is_missing() || dict == test_unzip_file(z)
    @test open_zip(z)["foo/text.txt"] == "text\n"
finally
    rm(z)
end


# Incremental ZIP to file...

f = tempname()
try
    open_zip(f, "w") do z
        z["hello.txt"] = "Hello!\n"
        z["foo/text.txt"] = "text\n"
    end
    @test dict == Dict(open_zip(f))
    open_zip(f) do z
        @test z["hello.txt"] == "Hello!\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["foo/text.txt"] == "text\n" # read again
    end

    # Add one file...
    open_zip(f, "r+") do z
        z["newfile"] = "new!\n"
    end
    open_zip(f) do z
        @test z["hello.txt"] == "Hello!\n"
        @test z["newfile"] == "new!\n"
        @test z["foo/text.txt"] == "text\n"
    end

    # Read and write (read first)...
    open_zip(f, "r+") do z
        z["hello.txt"] *= "World!\n"
        z["foo/bar.txt"] = "bar\n"
        z["foo/text.txt.copy"] = z["foo/text.txt"] * "Copy\n"
    end
    open_zip(f) do z
        @test z["hello.txt"] == "Hello!\nWorld!\n"
        @test z["foo/bar.txt"] == "bar\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["foo/text.txt.copy"] == "text\nCopy\n"
        @test z["foo/text.txt.copy"] == "text\nCopy\n" # read again
        @test z["newfile"] == "new!\n"
    end

    # Read and write (write first)...
    open_zip(f, "r+") do z
        z["foo/bar.txt"] = "bar\n"
        z["foo/text.txt.copy"] = z["foo/text.txt"] * "Copy\n"
    end
    open_zip(f) do z
        @test z["hello.txt"] == "Hello!\nWorld!\n"
        @test z["foo/bar.txt"] == "bar\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["foo/text.txt.copy"] == "text\nCopy\n"
        @test z["newfile"] == "new!\n"
    end

finally
    rm(f)
end

# Write new file, then read...
f = tempname()
try
    open_zip(f, "w+") do z
        z["hello.txt"] = "Hello!\n"
        z["foo/text.txt"] = "text\n"
        @test z["hello.txt"] == "Hello!\n"
    end
    @test dict == Dict(open_zip(f))

finally
    rm(f)
end


# Write new file, then iterate...
f = tempname()
try
    open_zip(f, "w+") do z
        z["hello.txt"] = "Hello!\n"
        z["foo/text.txt"] = "text\n"
        @test [(n,v) for (n,v) in z] == [("hello.txt","Hello!\n"),("foo/text.txt","text\n")]
    end
    @test dict == Dict(open_zip(f))

finally
    rm(f)
end


# Write new file, then read and write...
f = tempname()
try
    open_zip(f, "w+") do z
        z["hello.txt"] = "Hello!\n"
        z["foo/text.txt"] = "text\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["hello.txt"] == "Hello!\n"
        z["foo2/text.txt"] = "text\n"
    end
    open_zip(f) do z
        @test z["hello.txt"] == "Hello!\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["foo2/text.txt"] == "text\n"
    end

finally
    rm(f)
end



# Incremental ZIP to buffer...

buf = UInt8[]

    open_zip(buf) do z
        z["hello.txt"] = "Hello!\n"
        z["foo/text.txt"] = "text\n"
    end
    @test dict == Dict(open_zip(buf))
    open_zip(buf) do z
        @test z["hello.txt"] == "Hello!\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["foo/text.txt"] == "text\n" # read again
    end

    # Add one file...
    open_zip(buf) do z
        z["newfile"] = "new!\n"
    end
    open_zip(buf) do z
        @test z["hello.txt"] == "Hello!\n"
        @test z["newfile"] == "new!\n"
        @test z["foo/text.txt"] == "text\n"
    end

    # Read and write (read first)...
    open_zip(buf) do z
        z["hello.txt"] *= "World!\n"
        z["foo/bar.txt"] = "bar\n"
        z["foo/text.txt.copy"] = z["foo/text.txt"] * "Copy\n"
    end
    open_zip(buf) do z
        @test z["hello.txt"] == "Hello!\nWorld!\n"
        @test z["foo/bar.txt"] == "bar\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["foo/text.txt.copy"] == "text\nCopy\n"
        @test z["foo/text.txt.copy"] == "text\nCopy\n" # read again
        @test z["newfile"] == "new!\n"
    end

    # Read and write (write first)...
    open_zip(buf) do z
        z["foo/bar.txt"] = "bar\n"
        z["foo/text.txt.copy"] = z["foo/text.txt"] * "Copy\n"
    end
    open_zip(buf) do z
        @test z["hello.txt"] == "Hello!\nWorld!\n"
        @test z["foo/bar.txt"] == "bar\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["foo/text.txt.copy"] == "text\nCopy\n"
        @test z["newfile"] == "new!\n"
    end


# Write new buffer, then read...
buf = UInt8[]

    open_zip(buf) do z
        z["hello.txt"] = "Hello!\n"
        z["foo/text.txt"] = "text\n"
        @test z["hello.txt"] == "Hello!\n"
    end
    @test dict == Dict(open_zip(buf))



# Write new buffer, then iterate...
buf = UInt8[]

    open_zip(buf) do z
        z["hello.txt"] = "Hello!\n"
        z["foo/text.txt"] = "text\n"
        @test [(n,v) for (n,v) in z] == [("hello.txt","Hello!\n"),("foo/text.txt","text\n")]
    end
    @test dict == Dict(open_zip(buf))



# Write new buffer, then read and write...
buf = UInt8[]

    open_zip(buf) do z
        z["hello.txt"] = "Hello!\n"
        z["foo/text.txt"] = "text\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["hello.txt"] == "Hello!\n"
        z["foo2/text.txt"] = "text\n"
    end
    open_zip(buf) do z
        @test z["hello.txt"] == "Hello!\n"
        @test z["foo/text.txt"] == "text\n"
        @test z["foo2/text.txt"] == "text\n"
    end



# Unzip file created by command-line "zip" tool...

testzip = joinpath(Pkg.dir("ZipFile"),"test","test.zip")
d = Dict(open_zip(testzip))
@test sum(d["test.png"]) == 462242
delete!(d, "test.png")
@test dict == d


# unzip()...

mktempdir() do d
    open(testzip) do io
        ZipFile.unzip(io, d)
    end
    @test readall(joinpath(d, "hello.txt")) == "Hello!\n"
    @test readall(joinpath(d, "foo/text.txt")) == "text\n"

    @test dict == cd(()->Dict(open_zip(create_zip(["hello.txt", "foo/text.txt"]))), d)

end

mktempdir() do d
    ZipFile.unzip(testzip, d)
    @test readall(joinpath(d, "hello.txt")) == "Hello!\n"
    @test readall(joinpath(d, "foo/text.txt")) == "text\n"
end

mktempdir() do d
    ZipFile.unzip(create_zip(dict), d)
    @test readall(joinpath(d, "hello.txt")) == "Hello!\n"
    @test readall(joinpath(d, "foo/text.txt")) == "text\n"
end
