# Writer the byte b in w.
function write(w::WritableFile, b::UInt8)
    write(w, Ref(b))
end

# Read and return a byte from f. Throws EOFError if there is no more byte to read.
function read(f::ReadableFile, ::Type{UInt8})
    # This function needs to be fast because readbytes, readstring, etc.
    # uses it. Avoid function calls when possible.
    b = Vector{UInt8}(Compat.undef, 1)
    c = read(f, b)
    c[1]
end
