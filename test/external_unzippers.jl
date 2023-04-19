# Used to test that zip files written by ZipFile.jl can be read by other programs.
# This defines a vector of functions in `unzippers`
# These functions take a zipfile path and a directory path and extract the zipfile into the directory
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
    p7zip_jll.p7zip() do exe
        run(pipeline(`$(exe) x -y -o$(dirpath) $(zippath)`, devnull))
    end
    nothing
end

"""
Extract the zip file at zippath into the directory dirpath
Use bsdtar from libarchive
"""
function unzip_bsdtar(zippath, dirpath)
    LibArchive_jll.bsdtar() do exe
        run(`$(exe) -x -f $(zippath) -C $(dirpath)`)
    end
    nothing
end

"""
Extract the zip file at zippath into the directory dirpath
Use zipfile.py from python standard library
"""
function unzip_python(zippath, dirpath)
    zipfile = PyCall.pyimport("zipfile")
    PyCall.@pywith zipfile.ZipFile(zippath) as f begin
        isnothing(f.testzip()) || error(string(f.testzip()))
        f.extractall(dirpath)
    end
    nothing
end


# This is modified to only check for `unzip` from 
# https://github.com/samoconnor/InfoZIP.jl/blob/1247b24dd3183e00baa7890c1a2c7f6766c3d774/src/InfoZIP.jl#L6-L14
function have_infozip()
    try
        occursin(r"^UnZip.*by Info-ZIP", read(`unzip`, String))
    catch
        return false
    end
end

"""
Extract the zip file at zippath into the directory dirpath
Use unzip from the infamous builtin Info-ZIP
"""
function unzip_infozip(zippath, dirpath)
    try
        run(`unzip -qq $(zippath) -d $(dirpath)`)
    catch
        # unzip errors if the zip file is empty for some reason
    end
    nothing
end


unzippers = [
    unzip_p7zip,
    unzip_bsdtar,
    unzip_python,
]

if have_infozip()
    push!(unzippers, unzip_infozip)
else
    @info "system Info-ZIP unzip not found, skipping `unzip_infozip` tests"
end

