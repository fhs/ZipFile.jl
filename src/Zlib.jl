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

using Compat

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

if is_windows()
    const libz = "zlib1"
else
    const libz = "libz"
end

# The zlib z_stream structure.
type z_stream
    next_in::Ptr{UInt8}
    avail_in::Cuint
    total_in::Culong

    next_out::Ptr{UInt8}
    avail_out::Cuint
    total_out::Culong

    msg::Ptr{UInt8}
    state::Ptr{Void}

    zalloc::Ptr{Void}
    zfree::Ptr{Void}
    opaque::Ptr{Void}

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

type Writer <: IO
    strm::z_stream
    io::IO
    closed::Bool

    Writer(strm::z_stream, io::IO, closed::Bool) =
        (w = new(strm, io, closed); finalizer(w, close); w)
end

function Writer(io::IO, level::Integer, raw::Bool=false)
    if !(1 <= level <= 9)
        error("Invalid zlib compression level.")
    end

    strm = z_stream()
    ret = ccall((:deflateInit2_, libz),
                Int32, (Ptr{z_stream}, Cint, Cint, Cint, Cint, Cint, Ptr{UInt8}, Int32),
                &strm, level, 8, raw? -15 : 15, 8, 0, zlib_version(), sizeof(z_stream))

    if ret != Z_OK
        error("Error initializing zlib deflate stream.")
    end

    Writer(strm, io, false)
end

Writer(io::IO, raw::Bool=false) = Writer(io, 9, raw)

function write(w::Writer, p::Ptr, nb::Integer)
    w.strm.next_in = p
    w.strm.avail_in = nb
    outbuf = Vector{UInt8}(1024)

    while true
        w.strm.avail_out = length(outbuf)
        w.strm.next_out = pointer(outbuf)

        ret = ccall((:deflate, libz),
                    Int32, (Ptr{z_stream}, Int32),
                    &w.strm, Z_NO_FLUSH)
        if ret != Z_OK
            error("Error in zlib deflate stream ($(ret)).")
        end

        n = length(outbuf) - w.strm.avail_out
        if n > 0 && write(w.io, outbuf[1:n]) != n
            error("short write")
        end
        if w.strm.avail_out != 0
            break
        end
    end
    nb
end

write(w::Writer, a::Array{UInt8}) = write(w, pointer(a), length(a))

# If this is not provided, Base.IO write methods will write
# arrays one element at a time.
function write{T}(w::Writer, a::Array{T})
    if isbits(T)
        write(w, pointer(a), length(a)*sizeof(T))
    else
        invoke(write, Tuple{IO,Array}, w, a)
    end
end

# Copied from Julia base/io.jl
function write{T,N,A<:Array}(w::Writer, a::SubArray{T,N,A})
    if !isbits(T) || stride(a,1)!=1
        return invoke(write, Tuple{Any,AbstractArray}, s, a)
    end
    colsz = size(a,1)*sizeof(T)
    if N<=1
        return write(s, pointer(a, 1), colsz)
    else
        # WARNING: cartesianmap(f,dims) is deprecated, use for idx = CartesianRange(dims)
        #     f(idx.I...)

        if VERSION >= v"0.4.0-"
            for idx in CartesianRange(tuple(1, size(a)[2:end]...))
                write(w, pointer(a, idx.I), colsz)
            end
        else
            cartesianmap((idxs...)->write(w, pointer(a, idxs), colsz),
                        tuple(1, size(a)[2:end]...))
        end

        return colsz*Base.trailingsize(a,2)
    end
end

function write(w::Writer, b::UInt8)
    write(w, UInt8[b])
end

function close(w::Writer)
    if w.closed
        return
    end
    w.closed = true

    # flush zlib buffer using Z_FINISH
    inbuf = Vector{UInt8}(0)
    w.strm.next_in = pointer(inbuf)
    w.strm.avail_in = 0
    outbuf = Vector{UInt8}(1024)
    ret = Z_OK
    while ret != Z_STREAM_END
        w.strm.avail_out = length(outbuf)
        w.strm.next_out = pointer(outbuf)
        ret = ccall((:deflate, libz),
                    Int32, (Ptr{z_stream}, Int32),
                    &w.strm, Z_FINISH)
        if ret != Z_OK && ret != Z_STREAM_END
            error("Error in zlib deflate stream ($(ret)).")
        end
        n = length(outbuf) - w.strm.avail_out
        if n > 0 && write(w.io, outbuf[1:n]) != n
            error("short write")
        end
    end

    ret = ccall((:deflateEnd, libz), Int32, (Ptr{z_stream},), &w.strm)
    if ret == Z_STREAM_ERROR
        error("Error: zlib deflate stream was prematurely freed.")
    end
end


type Reader <: IO
    strm::z_stream
    io::IO
    buf::IOBuffer
    closed::Bool
    bufsize::Int
    stream_end::Bool

    Reader(strm::z_stream, io::IO, buf::IOBuffer, closed::Bool, bufsize::Int) =
        (r = new(strm, io, buf, closed, bufsize, false); finalizer(r, close); r)
end

function Reader(io::IO, raw::Bool=false; bufsize::Int=4096)
    strm = z_stream()
    ret = ccall((:inflateInit2_, libz),
                Int32, (Ptr{z_stream}, Cint, Ptr{UInt8}, Int32),
                &strm, raw? -15 : 47, zlib_version(), sizeof(z_stream))
    if ret != Z_OK
        error("Error initializing zlib inflate stream.")
    end

    Reader(strm, io, PipeBuffer(), false, bufsize)
end

# Fill up the buffer with at least minlen bytes of uncompressed data,
# unless we have already reached EOF.
function fillbuf(r::Reader, minlen::Integer)
    ret = Z_OK
    while nb_available(r.buf) < minlen && !eof(r.io) && ret != Z_STREAM_END
        input = read(r.io, UInt8, min(nb_available(r.io), r.bufsize))
        r.strm.next_in = pointer(input)
        r.strm.avail_in = length(input)
        #outbuf = Vector{UInt8}(r.bufsize)

        while true
            #r.strm.next_out = outbuf
            #r.strm.avail_out = length(outbuf)
            (r.strm.next_out, r.strm.avail_out) = Base.alloc_request(r.buf, convert(UInt, r.bufsize))
            actual_bufsize_out = r.strm.avail_out
            ret = ccall((:inflate, libz),
                        Int32, (Ptr{z_stream}, Int32),
                        &r.strm, Z_NO_FLUSH)
            if ret == Z_DATA_ERROR
                error("Error: input is not zlib compressed data: $(bytestring(r.strm.msg))")
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

    if ret == Z_STREAM_END
        r.stream_end = true
    end

    nb_available(r.buf)
end

# This is to fix the ambiguity with Base.read!
function read!(r::Reader, a::Vector{UInt8})
    nb = length(a)
    if fillbuf(r, nb) < nb
        throw(EOFError())
    end
    read!(r.buf, a)
    a
end

function read!{T}(r::Reader, a::Array{T})
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
    if nb_available(r.buf) < 1 && fillbuf(r, 1) < 1
        throw(EOFError())
    end
    read(r.buf, UInt8)
end

# This is faster than using the generic implementation in Base. We use
# it (indirectly) for decompress below.
readbytes!(r::Reader, b::AbstractArray{UInt8}, nb=length(b)) =
    readbytes!(r.buf, b, fillbuf(r, nb))

function readuntil(r::Reader, delim::UInt8)
    nb = search(r.buf, delim)
    while nb == 0
        offset = nb_available(r.buf)
        fillbuf(r, offset+r.bufsize)
        if nb_available(r.buf) == nb
            break
        end
        # TODO: add offset here when https://github.com/JuliaLang/julia/pull/4485
        # is merged
        nb = search(r.buf, delim) #, offset)
    end
    if nb == 0;  nb == nb_available(r.buf); end
    read!(r.buf, Vector{UInt8}(nb))
end

function close(r::Reader)
    if r.closed
        return
    end
    r.closed = true

    ret = ccall((:inflateEnd, libz), Int32, (Ptr{z_stream},), &r.strm)
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
    nb_available(r.buf) == 0 && eof(r.io)
end

function crc32(data::Vector{UInt8}, crc::Integer=0)
    convert(UInt32, (ccall((:crc32, libz),
                 Culong, (Culong, Ptr{UInt8}, Cuint),
                 crc, data, length(data))))
end

crc32(data::AbstractString, crc::Integer=0) = crc32(convert(Vector{UInt8}, data), crc)

end # module
