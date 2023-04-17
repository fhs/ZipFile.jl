# Test that zip files written by ZipFile.jl can be read by other programs.
using Test
using ZipFile
import p7zip_jll


"""
Extract the zip file at zippath into the directory dirpath
Use p7zip
"""
function unzip_p7zip(zippath, dirpath)
    p7zip_jll.p7zip() do exe
        run(pipeline(`$(exe) x -y -o$(dirpath) $(zippath)`, devnull))
    end
end

@testset "Writer is compatible with p7zip" begin
    # write an empty zip file
    mktempdir() do tmp
        zippath = joinpath(tmp, "empty.zip")
        dirpath = joinpath(tmp, "empty_p7zip_out")
        mkpath(dirpath)
        dir = ZipFile.Writer(zippath)
        close(dir)
        unzip_p7zip(zippath, dirpath)
        @test isempty(readdir(dirpath))
    end

    # write a zip file with some basic ASCII files with ASCII file names
    mktempdir() do tmp
        zippath = joinpath(tmp, "hello.zip")
        dirpath = joinpath(tmp, "hello_p7zip_out")
        mkpath(dirpath)
        zipdata = [
            ("hello.txt", "hello world!\n", ZipFile.Store),
            ("info.txt", "Julia\nfor\ntechnical computing\n", ZipFile.Store),
            ("julia.txt", "julia\n"^10, ZipFile.Deflate),
            ("empty1.txt", "", ZipFile.Store),
            ("empty2.txt", "", ZipFile.Deflate),
        ]
        dir = ZipFile.Writer(zippath)
        for (name, data, meth) in zipdata
            local f = ZipFile.addfile(dir, name; method=meth)
            write(f, data)
        end
        close(dir)
        
        unzip_p7zip(zippath, dirpath)
        @test length(readdir(dirpath)) == length(zipdata)
        for (name, data, meth) in zipdata
            @test read(joinpath(dirpath,name), String) == data
        end
    end

    # write a zip file with UTF8 filenames
    mktempdir() do tmp
        zippath = joinpath(tmp, "utf8.zip")
        dirpath = joinpath(tmp, "utf8_p7zip_out")
        mkpath(dirpath)
        zipdata = [
            ("hello😸.txt", "hello world!\n", ZipFile.Store),
        ]
        dir = ZipFile.Writer(zippath)
        for (name, data, meth) in zipdata
            local f = ZipFile.addfile(dir, name; method=meth)
            write(f, data)
        end
        close(dir)
        
        unzip_p7zip(zippath, dirpath)
        @test length(readdir(dirpath)) == length(zipdata)
        for (name, data, meth) in zipdata
            @test_broken read(joinpath(dirpath,name), String) == data
        end
    end
end

