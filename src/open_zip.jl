module OpenZip

export open_zip, unzip

import ..ZipFile: Reader, ReadableFile, with_close, mkpath_write


# Open a ZIP archive.

open_zip(io::IO) = Reader(io)
open_zip(data::Array{UInt8,1}) = Reader(IOBuffer(data))
open_zip(f::Function, args...) = with_io(f, open_zip(args...))
open_zip(filename::AbstractString) = Reader(filename)


# Read file from ZIP using Associative syntax: data = z[filename].

function Base.getindex(z::Reader, filename::AbstractString)

    for f in z.files
        if f.name == filename
            return readfile(f)
        end
    end
    nothing
end


# Read files from ZIP using iterator syntax.

Base.eltype(z::Reader) = Pair{AbstractString,Union{AbstractString,
                                                      Array{UInt8,1}}}
Base.start(z::Reader) = start(z.files)
Base.done(z::Reader, state) = done(z.files, state)
Base.length(z::Reader) = length(z.files)

function Base.next(z::Reader, state)
    f, state = next(z.files, state)
    if basename(f.name) == ""
        return next(z, state)
    end
    ((f.name, readfile(f)), state)
end


function readfile(io::ReadableFile)
     b = readbytes(io)
     return isvalid(ASCIIString, b) ? ASCIIString(b) :
            isvalid(UTF8String, b)  ? UTF8String(b)  : b
end


# Extract ZIP archive to "outputpath".
# Based on fhs/ZipFile.jl#16, thanks @timholy.

function unzip(archive, outputpath::AbstractString=pwd())
    for (filename, data) in open_zip(archive)
        filename = joinpath(outputpath, filename)
        mkpath_write(filename, data)
    end
end



end # module ZIP
