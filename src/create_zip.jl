# Write content of "dict" to "io" in ZIP format.

function create_zip{T<:Associative}(io::IO, dict::T)

    open_zip(io) do z
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



# Write ZIP Archive to "filename".

function create_zip(filename::AbstractString, args...)
    create_zip(Base.open(filename, "w"), args...)
end


# Use temporary memory buffer if "filename" or "io" are not provided.

function create_zip(arg, args...)

    buf = UInt8[]
    with_close(IOBuffer(buf, true, true)) do io
        create_zip(io, arg, args...)
    end
    buf
end
