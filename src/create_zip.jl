module CreateZip

import ..ZipFile: Writer, addfile, with_close, Deflate

export create_zip 


# Create a new ZIP archive.

create_zip(io::IO) = Writer(io)
create_zip(buf::Array{UInt8,1}) = create_zip(IOBuffer(buf, false, true))
create_zip(f::Function, arg, args...) = with_close(f, create_zip(arg, args...))
create_zip(filename::AbstractString) = Writer(filename)

function create_zip(filename::AbstractString, arg, args...)
    create_zip(open(filename, "w"), arg, args...)
end


# Use memory buffer if "filename" or "io" is provided.

function create_zip(arg, args...)

    with_close(IOBuffer()) do io
        create_zip(io, arg, args...)
        takebuf_array(io)
    end
end


# Add files to ZIP using Associative syntax: z[filename] = data.

function Base.setindex!(z::Writer, data, filename::AbstractString)

    with_close(addfile(z, filename, method=Deflate)) do io
        write(io, data)
    end
    nothing
end


# Write content of "dict" to "io" in ZIP format.

function create_zip{T<:Associative}(io::IO, dict::T)

    create_zip(io) do z
        for (filename, data) in dict
            z[string(filename)] = data
        end
    end
    nothing
end


# Write to ZIP format from (filename, data) tuples.

create_zip{T<:Tuple}(io::IO, files::Array{T}) = create_zip(io, files...)


# Write "files" and "data" to ZIP format.

create_zip(io::IO, files::Array, data::Array) = create_zip(io, zip(files, data)...)


# Write to ZIP format from filename => data pairs.

create_zip(io::IO, args...) = create_zip(io::IO, Dict(args))



end # module CreateZIP
