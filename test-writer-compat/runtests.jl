# Test that zip files written by ZipFile.jl can be read by other programs.
# This test requires julia 1.6 or greater to run.
using Test
using ZipFile
import p7zip_jll
import LibArchive_jll
import PyCall



"""
Extract the zip file at zippath into the directory dirpath
Use p7zip
"""
function unzip_p7zip(zippath, dirpath)
    # pipe output to devnull because p7zip is noisy
    run(pipeline(`$(p7zip_jll.p7zip()) x -y -o$(dirpath) $(zippath)`, devnull))
    nothing
end

"""
Extract the zip file at zippath into the directory dirpath
Use bsdtar from libarchive
"""
function unzip_bsdtar(zippath, dirpath)
    run(`$(LibArchive_jll.bsdtar()) -x -f $(zippath) -C $(dirpath)`)
    nothing
end

"""
Extract the zip file at zippath into the directory dirpath
Use zipfile.py from python standard library
"""
function unzip_python(zippath, dirpath)
    zipfile = PyCall.pyimport("zipfile")
    f = zipfile.ZipFile(zippath)
    isnothing(f.testzip()) || error(string(f.testzip()))
    f.extractall(dirpath)
    nothing
end


"""
Use ZipFile.Writer to write a bunch of zip files to a directory
"""
function write_example_zipfiles(dirpath::AbstractString)
    # write an empty zip file
    dir = ZipFile.Writer(joinpath(dirpath, "empty.zip"))
    close(dir)

    # write a zip file with some basic ASCII files with ASCII file names
    zipdata = [
        ("hello.txt", "hello world!\n", ZipFile.Store),
        ("info.txt", "Julia\nfor\ntechnical computing\n", ZipFile.Store),
        ("julia.txt", "julia\n"^10, ZipFile.Deflate),
        ("empty1.txt", "", ZipFile.Store),
        ("empty2.txt", "", ZipFile.Deflate),
    ]
    dir = ZipFile.Writer(joinpath(dirpath, "hello.zip"))
    for (name, data, meth) in zipdata
        local f = ZipFile.addfile(dir, name; method=meth)
        write(f, data)
    end
    close(dir)

    # TODO fix write a zip file with UTF8 filenames
    # zipdata = [
    #     ("hello😸.txt", "hello world!\n", ZipFile.Store),
    # ]
    # dir = ZipFile.Writer(joinpath(dirpath, "utf8.zip"))
    # for (name, data, meth) in zipdata
    #     local f = ZipFile.addfile(dir, name; method=meth)
    #     write(f, data)
    # end
    # close(dir)
end

Debug = false

tmp = mktempdir()
if Debug
    println("temporary directory $tmp")
end

write_example_zipfiles(tmp)

# Functions that can unzip into a directory
unzippers = [
    unzip_p7zip,
    unzip_bsdtar,
    unzip_python,
]

@testset "Writer compat with $(unzipper)" for unzipper in unzippers
    for zippath in readdir(tmp; join=true)
        mktempdir() do tmpout
            # Unzip into an output directory
            unzipper(zippath, tmpout)
            # Read zippath with ZipFile.Reader
            # Check file names and data match
            local dir = ZipFile.Reader(zippath)
            for f in dir.files
                local name = f.name
                local extracted_path = joinpath(tmpout,name)
                @test isfile(extracted_path)
                @test read(f) == read(extracted_path)
            end
        end
    end
end