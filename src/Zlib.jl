# This file was copied from https://github.com/dcjones/Zlib.jl
#
# Zlib is licensed under the MIT License:
#
# > Copyright (c) 2013: Daniel C. Jones
# >
# > Permission is hereby granted, free of charge, to any person obtaining
# > a copy of this software and associated documentation files (the
# > "Software"), to deal in the Software without restriction, including
# > without limitation the rights to use, copy, modify, merge, publish,
# > distribute, sublicense, and/or sell copies of the Software, and to
# > permit persons to whom the Software is furnished to do so, subject to
# > the following conditions:
# >
# > The above copyright notice and this permission notice shall be
# > included in all copies or substantial portions of the Software.
# >
# > THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# > EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# > MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# > NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# > LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# > OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# > WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

module Zlib
using Zlib_jll

import Base: read, read!, readuntil, readbytes!, write, close, eof

export compress, decompress, crc32

const Z_NO_FLUSH      = 0
const Z_PARTIAL_FLUSH = 1
const Z_SYNC_FLUSH    = 2
const Z_FULL_FLUSH    = 3
const Z_FINISH        = 4
const Z_BLOCK         = 5
const Z_TREES         = 6

const Z_OK            = 0
const Z_STREAM_END    = 1
const Z_NEED_DICT     = 2
const ZERRNO          = -1
const Z_STREAM_ERROR  = -2
const Z_DATA_ERROR    = -3
const Z_MEM_ERROR     = -4
const Z_BUF_ERROR     = -5
const Z_VERSION_ERROR = -6


# The zlib z_stream structure.
mutable struct z_stream
    next_in::Ptr{UInt8}
    avail_in::Cuint
    total_in::Culong

    next_out::Ptr{UInt8}
    avail_out::Cuint
    total_out::Culong

    msg::Ptr{UInt8}
    state::Ptr{Cvoid}

    zalloc::Ptr{Cvoid}
    zfree::Ptr{Cvoid}
    opaque::Ptr{Cvoid}

    data_type::Cint
    adler::Culong
    reserved::Culong

    function z_stream()
        strm = new()
        strm.next_in   = C_NULL
        strm.avail_in  = 0
        strm.total_in  = 0
        strm.next_out  = C_NULL
        strm.avail_out = 0
        strm.total_out = 0
        strm.msg       = C_NULL
        strm.state     = C_NULL
        strm.zalloc    = C_NULL
        strm.zfree     = C_NULL
        strm.opaque    = C_NULL
        strm.data_type = 0
        strm.adler     = 0
        strm.reserved  = 0
        strm
    end
end

function zlib_version()
    ccall((:zlibVersion, libz), Ptr{UInt8}, ())
end

mutable struct Writer <: IO
    strm::z_stream
    io::IO
    closed::Bool

    Writer(strm::z_stream, io::IO, closed::Bool) =
        (w = new(strm, io, closed); finalizer(close, w); w)
end

function Writer(io::IO, level::Integer, raw::Bool=false)
    if !(1 <= level <= 9)
        error("Invalid zlib compression level.")
    end

    strm = z_stream()
    ret = ccall((:deflateInit2_, libz),
                Int32, (Ptr{z_stream}, Cint, Cint, Cint, Cint, Cint, Ptr{UInt8}, Int32),
                Ref(strm), level, 8, raw ? -15 : 15, 8, 0, zlib_version(), sizeof(z_stream))

    if ret != Z_OK
        error("Error initializing zlib deflate stream.")
    end

    Writer(strm, io, false)
end

Writer(io::IO, raw::Bool=false) = Writer(io, 9, raw)

function Base.unsafe_write(w::Writer, p::Ptr{UInt8}, nb::UInt)::UInt
    if nb == 0
        return UInt(0)
    end
    max_chunk_size::UInt = UInt(typemax(Cuint))>>1
    chunk_offset = UInt(0)
    num_bytes_left = nb
    chunk_size = min(max_chunk_size, num_bytes_left)
    w.strm.avail_in = chunk_size
    w.strm.next_in = p
    outbuf = Vector{UInt8}(undef, 1024)
    GC.@preserve outbuf while true
        w.strm.avail_out = length(outbuf)
        w.strm.next_out = pointer(outbuf)
        ret = ccall((:deflate, libz),
                    Int32, (Ptr{z_stream}, Int32),
                    Ref(w.strm), Z_NO_FLUSH)
        if ret != Z_OK
            error("Error in zlib deflate stream ($(ret)).")
        end

        n = length(outbuf) - w.strm.avail_out
        if n > 0 && write(w.io, view(outbuf,1:n)) != n
            error("short write")
        end
        # Update w.strm.avail_in if needed
        if w.strm.avail_in == 0
            # mark that previous chunk was written
            chunk_offset += chunk_size
            num_bytes_left -= chunk_size
            # new chunk size, will be zero at the end.
            chunk_size = min(max_chunk_size, num_bytes_left)
            @assert chunk_offset + chunk_size ≤ nb
            w.strm.next_in = p + chunk_offset
            w.strm.avail_in = chunk_size
        end
        if (w.strm.avail_out != 0) && (w.strm.avail_in == 0)
            break
        end
    end
    w.strm.next_in = C_NULL
    w.strm.next_out = C_NULL
    nb
end

function write(w::Writer, b::UInt8)
    write(w, Ref(b))
end

function close(w::Writer)
    if w.closed
        return
    end
    w.closed = true

    # flush zlib buffer using Z_FINISH
    inbuf = Ref{UInt8}(0)
    outbuf = Vector{UInt8}(undef, 1024)
    GC.@preserve inbuf outbuf begin
        w.strm.next_in = Base.unsafe_convert(Ptr{UInt8}, inbuf)
        w.strm.avail_in = 0
        ret = Z_OK
        while ret != Z_STREAM_END
            w.strm.avail_out = length(outbuf)
            w.strm.next_out = pointer(outbuf)
            ret = ccall((:deflate, libz),
                        Int32, (Ptr{z_stream}, Int32),
                        Ref(w.strm), Z_FINISH)
            if ret != Z_OK && ret != Z_STREAM_END
                error("Error in zlib deflate stream ($(ret)).")
            end
            n = length(outbuf) - w.strm.avail_out
            if n > 0 && write(w.io, outbuf[1:n]) != n
                error("short write")
            end
        end

        ret = ccall((:deflateEnd, libz), Int32, (Ptr{z_stream},), Ref(w.strm))
        if ret == Z_STREAM_ERROR
            error("Error: zlib deflate stream was prematurely freed.")
        end
    end
    w.strm.next_in = C_NULL
    w.strm.next_out = C_NULL
end


mutable struct Reader <: IO
    strm::z_stream
    io::IO
    buf::IOBuffer
    closed::Bool
    bufsize::Int
    stream_end::Bool

    Reader(strm::z_stream, io::IO, buf::IOBuffer, closed::Bool, bufsize::Int) =
        (r = new(strm, io, buf, closed, bufsize, false); finalizer(close, r); r)
end

function Reader(io::IO, raw::Bool=false; bufsize::Int=4096)
    strm = z_stream()
    ret = ccall((:inflateInit2_, libz),
                Int32, (Ptr{z_stream}, Cint, Ptr{UInt8}, Int32),
                Ref(strm), raw ? -15 : 47, zlib_version(), sizeof(z_stream))
    if ret != Z_OK
        error("Error initializing zlib inflate stream.")
    end

    Reader(strm, io, PipeBuffer(), false, bufsize)
end

# Fill up the buffer with at least minlen bytes of uncompressed data,
# unless we have already reached EOF.
function fillbuf(r::Reader, minlen::Integer)
    ret = Z_OK
    while bytesavailable(r.buf) < minlen && !eof(r.io) && ret != Z_STREAM_END
        input = read!(r.io, Array{UInt8}(undef, min(bytesavailable(r.io), r.bufsize)))
        r.strm.next_in = pointer(input)
        r.strm.avail_in = length(input)
        #outbuf = Vector{UInt8}(undef, r.bufsize)

        r_buf = r.buf # GC.@preserve only accepts symbols
        GC.@preserve input r_buf while true
            #r.strm.next_out = outbuf
            #r.strm.avail_out = length(outbuf)
            (r.strm.next_out, r.strm.avail_out) = Base.alloc_request(r.buf, convert(UInt, r.bufsize))
            actual_bufsize_out = r.strm.avail_out
            ret = ccall((:inflate, libz),
                        Int32, (Ptr{z_stream}, Int32),
                        Ref(r.strm), Z_NO_FLUSH)
            if ret == Z_DATA_ERROR
                error("Error: input is not zlib compressed data: $(unsafe_string(r.strm.msg))")
            elseif ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR
                error("Error in zlib inflate stream ($(ret)).")
            end
            if (nbytes = actual_bufsize_out - r.strm.avail_out) > 0
                #write(r.buf, pointer(outbuf), nbytes)
                # TODO: the last two parameters are not used by notify_filled()
                # and can be removed if Julia PR #4484 is merged
                Base.notify_filled(r.buf, convert(Int, nbytes), C_NULL, convert(UInt, 0))
            end
            if r.strm.avail_out != 0
                break
            end
        end
    end
    r.strm.next_in = C_NULL
    r.strm.next_out = C_NULL

    if ret == Z_STREAM_END
        r.stream_end = true
    end

    bytesavailable(r.buf)
end

# This is to fix the ambiguity with Base.read!
function read!(r::Reader, a::Array{UInt8, N}) where N
    nb = length(a)
    if fillbuf(r, nb) < nb
        throw(EOFError())
    end
    read!(r.buf, a)
    a
end

function read!(r::Reader, a::Array{T}) where T
    if isbits(T)
        nb = length(a)*sizeof(T)
        if fillbuf(r, nb) < nb
            throw(EOFError())
        end
        read!(r.buf, a)
    else
        invoke(read!, Tuple{IO,Array}, r, a)
    end
    a
end

# This function needs to be fast because other read calls use it.
function read(r::Reader, ::Type{UInt8})
    if bytesavailable(r.buf) < 1 && fillbuf(r, 1) < 1
        throw(EOFError())
    end
    read(r.buf, UInt8)
end

# This is faster than using the generic implementation in Base. We use
# it (indirectly) for decompress below.
readbytes!(r::Reader, b::AbstractArray{UInt8}, nb=length(b)) =
    readbytes!(r.buf, b, fillbuf(r, nb))

function readuntil(r::Reader, delim::UInt8)
    nb = readuntil(r.buf, delim)
    while nb == 0
        offset = bytesavailable(r.buf)
        fillbuf(r, offset+r.bufsize)
        if bytesavailable(r.buf) == nb
            break
        end
        # TODO: add offset here when https://github.com/JuliaLang/julia/pull/4485
        # is merged
        nb = readuntil(r.buf, delim) #, offset)
    end
    if nb == 0;  nb == bytesavailable(r.buf); end
    read!(r.buf, Vector{UInt8}(undef, nb))
end

function close(r::Reader)
    if r.closed
        return
    end
    r.closed = true

    ret = ccall((:inflateEnd, libz), Int32, (Ptr{z_stream},), Ref(r.strm))
    if ret == Z_STREAM_ERROR
        error("Error: zlib inflate stream was prematurely freed.")
    end
end

function eof(r::Reader)
    # Detecting EOF is somewhat tricky: we might not have reached
    # EOF in r.io but decompressing the remaining data might
    # yield no uncompressed data. So, make sure we can get at least
    # one more byte of decompressed data before we say we haven't
    # reached EOF yet.
    bytesavailable(r.buf) == 0 && eof(r.io)
end

function unsafe_crc32(p::Ptr{UInt8}, nb::UInt, crc::UInt32)::UInt32
    max_chunk_size::UInt = UInt(typemax(Cuint))>>1
    chunk_offset = UInt(0)
    num_bytes_left = nb
    while num_bytes_left > 0
        chunk_size = min(max_chunk_size, num_bytes_left)
        @assert chunk_offset + chunk_size ≤ nb
        crc::UInt32 = ccall((:crc32, libz),
            Culong, (Culong, Ptr{UInt8}, Cuint),
            crc, p + chunk_offset, chunk_size,
        )
        chunk_offset += chunk_size
        num_bytes_left -= chunk_size
    end
    crc
end

function crc32(data::AbstractArray{UInt8}, crc::Integer=0)::UInt32
    GC.@preserve data begin
        unsafe_crc32(pointer(data), UInt(length(data)), UInt32(crc))
    end
end

crc32(data::AbstractString, crc::Integer=0) = crc32(convert(AbstractArray{UInt8}, data), crc)

end # module
