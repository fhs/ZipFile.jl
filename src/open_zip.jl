# Wrapper type.

type ZipArchive <: Associative
    io::IO
    reader
    writer
    cache::Dict
    cache_is_active::Bool
end


# Create ZipArchive interface for "io".
# Try to create a Reader, but don't read anything yet.
# If the archive is being newly created, "reader" will be "nothing".

function ZipArchive(io::IO)

    reader = nothing
    cache = Dict()
    try
        reader = Reader(io, close_io=false)  
        cache = Dict([f.name => "" for f in reader.files])
    end
    ZipArchive(io, reader, nothing, cache, false)
end


# Open a ZIP Archive from io, buffer or file.

open_zip(io::IO) = ZipArchive(io)
open_zip(data::Array{UInt8,1}) = ZipArchive(IOBuffer(data, true, true))
open_zip(filename::AbstractString) = ZipArchive(Base.open(filename))
open_zip(filename::AbstractString, mode) = ZipArchive(Base.open(filename, mode))

open_zip(f::Function, args...) = with_close(f, open_zip(args...))


function Base.close(z::ZipArchive)

    # Write out cached files...
    if z.cache_is_active
        z.cache_is_active = false
        for (n,v) in z.cache
            z[n] = v
        end
    end

    # Close reader, writer and io...
    z.reader == nothing || close(z.reader)
    z.writer == nothing || close(z.writer)
    close(z.io)
end


# Read file from ZIP using Associative syntax: data = z[filename].

function Base.get(z::ZipArchive, filename::AbstractString, default=nothing)

    # In read/write mode, read from cache...
    if z.cache_is_active
        return get(z.cache, filename, default)
    end

    # Reading with no Reader!
    # Close the Writer and create a new Reader...
    if z.reader == nothing
        @assert z.writer != nothing
        close(z.writer)
        z.writer = nothing
        seek(z.io,0)
        z.reader = Reader(z.io, close_io=false)  
    end

    # Search Reader file list for "filename"...
    for f in z.reader.files
        if f.name == filename
            rewind(f)
            return readfile(f)
        end
    end

    return default
end


# Add files to ZIP using Associative syntax: z[filename] = data.

function Base.setindex!(z::ZipArchive, data, filename::AbstractString)

    # If there is an active reader, then setindex!() is writing to a
    # ZIP Archive that already has content.
    # Load all the existsing content into the cache then close the Reader.
    # The cached content will be written out to the new file later in close().
    if z.reader != nothing
        @assert z.writer == nothing
        z.cache = Dict(collect(z))
        z.cache_is_active = true
        close(z.reader)
        z.reader = nothing
        truncate(z.io, 0)
    end
        
    # In read/write mode, write to the cache...
    if z.cache_is_active
        return setindex!(z.cache, data, filename)
    end

    # Create a writer as needed...
    if z.writer == nothing
        z.writer = Writer(z.io, close_io=false)
    end

    # Write "data" for "filename" to Zip Archive...
    with_close(addfile(z.writer, filename, method=Deflate)) do io
        write(io, data)
    end

    # Store "filename" in cache so that keys() always has a full list of
    # the ZIP Archive's content...
    setindex!(z.cache, "", filename)

    return data
end



# Read files from ZIP using iterator syntax.
# The iterator wraps the z.cache iterator. However, unless mixed read/write
# calls have occured, the cache holds only filenames, so get(z, filename) is
# called to read the data from the archive.

Base.keys(z::ZipArchive) = keys(z.cache)
Base.eltype(z::ZipArchive) = Tuple{ByteString, Union{ByteString, Vector{UInt8}}}
Base.length(z::ZipArchive) = length(z.cache)
Base.start(z::ZipArchive) = start(z.cache)
Base.done(z::ZipArchive, state) = done(z.cache, state)

function Base.next(z::ZipArchive, state)
    ((filename, data), state) = next(z.cache, state)
    if basename(filename) == ""
        return next(z, state)
    end
    if data == ""
        data = get(z, filename)
    end
    ((filename, data), state)
end


# Read entire file...

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
