"""
A Julia package for reading/writing ZIP archive files

This package provides support for reading and writing ZIP archives in Julia.
Install it via the Julia package manager using ``Pkg.add("ZipFile")``.

The ZIP file format is described in
http://www.pkware.com/documents/casestudies/APPNOTE.TXT

# Example
The example below writes a new ZIP file and then reads back the contents.
```
julia> using ZipFile
julia> w = ZipFile.Writer("/tmp/example.zip");
julia> f = ZipFile.addfile(w, "hello.txt");
julia> write(f, "hello world!\n");
julia> f = ZipFile.addfile(w, "julia.txt", method=ZipFile.Deflate);
julia> write(f, "Julia\n"^5);
julia> close(w)
julia> r = ZipFile.Reader("/tmp/example.zip");
julia> for f in r.files
          println("Filename: \$(f.name)")
          write(stdout, read(f, String));
       end
julia> close(r)
Filename: hello.txt
hello world!
Filename: julia.txt
Julia
Julia
Julia
Julia
Julia
```
"""
module ZipFile

import Base: read, read!, eof, write, flush, close, mtime, position, show, unsafe_write
using Printf

export read, read!, eof, write, close, mtime, position, show

include("Zlib.jl")
import .Zlib

# TODO: ZIP64 support, data descriptor support

const _LocalFileHdrSig   = 0x04034b50
const _CentralDirSig     = 0x02014b50
const _EndCentralDirSig  = 0x06054b50
const _Zip64EndCentralLocSig = 0x07064b50
const _Zip64EndCentralDirSig = 0x06064b50
const _ZipVersion = 20

"Compression method that does no compression"
const Store = UInt16(0)

"Deflate compression method"
const Deflate = UInt16(8)

const _Method2Str = Dict{UInt16,String}(Store => "Store", Deflate => "Deflate")

mutable struct ReadableFile <: IO
    _io :: IO
    name :: String   # filename
    method :: UInt16            # compression method
    dostime :: UInt16           # modification time in MS-DOS format
    dosdate :: UInt16           # modification date in MS-DOS format
    crc32 :: UInt32             # CRC32 of uncompressed data
    compressedsize :: UInt64    # file size after compression
    uncompressedsize :: UInt64  # size of uncompressed file
    _offset :: UInt64
    _datapos :: Int64   # position where data begins
    _zio :: IO          # compression IO

    _currentcrc32 :: UInt32
    _pos :: Int64       # current position in uncompressed data
    _zpos :: Int64      # current position in compressed data

	function ReadableFile(io::IO, name::AbstractString, method::UInt16, dostime::UInt16,
		dosdate::UInt16, crc32::UInt32, compressedsize::Unsigned,
		uncompressedsize::Unsigned, _offset::Unsigned)
		if method != Store && method != Deflate
			error("unknown compression method $method")
		end
		new(io, name, method, dostime, dosdate, crc32,
		    compressedsize, uncompressedsize, _offset, -1, io, 0, 0, 0)
	end
end

"""
Reader represents a ZIP file open for reading.

    Reader(io::IO)
    Reader(filename::AbstractString)

Read a ZIP file from io or the file named filename.
"""
mutable struct Reader
    _io :: IO
    _close_io :: Bool
    files :: Vector{ReadableFile} # ZIP file entries that can be read concurrently
    comment :: String  # ZIP file comment

    function Reader(io::IO, close_io::Bool)
        endoff = _find_enddiroffset(io)
        diroff, nfiles, comment = _find_diroffset(io, endoff)
        files = _getfiles(io, diroff, nfiles)
        x = new(io, close_io, files, comment)
        finalizer(close, x)
        x
    end
end

function Reader(io::IO)
    Reader(io, false)
end

function Reader(filename::AbstractString)
    Reader(Base.open(filename), true)
end

mutable struct WritableFile <: IO
    _io :: IO
    name :: String   # filename
    method :: UInt16            # compression method
    dostime :: UInt16           # modification time in MS-DOS format
    dosdate :: UInt16           # modification date in MS-DOS format
    crc32 :: UInt32             # CRC32 of uncompressed data
    compressedsize :: UInt32    # file size after compression
    uncompressedsize :: UInt32  # size of uncompressed file
    _offset :: UInt32
    _datapos :: Int64   # position where data begins
    _zio :: IO          # compression IO

    _closed :: Bool

    function WritableFile(io::IO, name::AbstractString, method::UInt16, dostime::UInt16,
            dosdate::UInt16, crc32::UInt32, compressedsize::UInt32,
            uncompressedsize::UInt32, _offset::UInt32, _datapos::Int64,
            _zio::IO, _closed::Bool)
        if method != Store && method != Deflate
            error("unknown compression method $method")
        end
        f = new(io, name, method, dostime, dosdate, crc32,
            compressedsize, uncompressedsize, _offset, _datapos, _zio, _closed)
        finalizer(close, f)
        f
    end
end

"""
Writer represents a ZIP file open for writing.

    Writer(io::IO)
    Writer(filename::AbstractString)

Create a new ZIP file that will be written to io or the file named filename.
"""
mutable struct Writer
    _io :: IO
    _close_io :: Bool
    files :: Vector{WritableFile} # files (being) written
    _current :: Union{WritableFile, Nothing}
    _closed :: Bool

    function Writer(io::IO, close_io::Bool)
        x = new(io, close_io, WritableFile[], nothing, false)
        finalizer(close, x)
        x
    end
end

function Writer(io::IO)
    Writer(io, false)
end

function Writer(filename::AbstractString)
    Writer(Base.open(filename, "w"), true)
end

# Print out a summary of f in a human-readable format.
function show(io::IO, f::Union{ReadableFile, WritableFile})
    print(io, "$(string(typeof(f)))(name=$(f.name), method=$(_Method2Str[f.method]), uncompresssedsize=$(f.uncompressedsize), compressedsize=$(f.compressedsize), mtime=$(mtime(f)))")
end

# Print out a summary of rw in a human-readable format.
function show(io::IO, rw::Union{Reader, Writer})
    println(io, "$(string(typeof(rw))) for $(rw._io) containing $(length(rw.files)) files:\n")
    @printf(io, "%16s %-7s %-16s %s\n", "uncompressedsize", "method", "mtime", "name")
    println(io, "-"^(16+1+7+1+16+1+4))
    for f in rw.files
        ftime = Libc.strftime("%Y-%m-%d %H-%M", mtime(f))
        @printf(io, "%16d %-7s %-16s %s\n",
            f.uncompressedsize, _Method2Str[f.method], ftime, f.name)

    end
end

include("deprecated.jl")
include("iojunk.jl")

if isdefined(Core, :String) && isdefined(Core, :AbstractString)
    function utf8_validate(vec::Vector{UInt8})
        s = String(vec)
        isvalid(s) || throw(ArgumentError("Invalid utf8 string: $vec"))
        return s
    end
else
    utf8_validate(vec::Vector{UInt8}) = utf8(vec)
end

readle(io::IO, ::Type{UInt64}) = htol(read(io, UInt64))
readle(io::IO, ::Type{UInt32}) = htol(read(io, UInt32))
readle(io::IO, ::Type{UInt16}) = htol(read(io, UInt16))

function _writele(io::IO, x::Vector{UInt8})
    n = write(io, x)
    if n != length(x)
        error("short write")
    end
    n
end

_writele(io::IO, x::UInt16) = _writele(io, Vector{UInt8}(reinterpret(UInt8, [htol(x)])))
_writele(io::IO, x::UInt32) = _writele(io, Vector{UInt8}(reinterpret(UInt8, [htol(x)])))

# For MS-DOS time/date format, see:
# http://msdn.microsoft.com/en-us/library/ms724247(v=VS.85).aspx

# Convert seconds since epoch to MS-DOS time/date, which has
# a resolution of 2 seconds.
function _msdostime(secs::Float64)
    t = Libc.TmStruct(secs)
    dostime = UInt16((t.hour<<11) | (t.min<<5) | div(t.sec, 2))
    dosdate = UInt16(((t.year+1900-1980)<<9) | ((t.month+1)<<5) | t.mday)
    dostime, dosdate
end

# Convert MS-DOS time/date to seconds since epoch
function _mtime(dostime::UInt16, dosdate::UInt16)
    sec = 2*(dostime & 0x1f)
    min = (dostime>>5) & 0x3f
    hour = dostime>>11
    mday = dosdate & 0x1f
    month = ((dosdate>>5) & 0xf) - 1
    year = (dosdate>>9) + 1980 - 1900
    time(Libc.TmStruct(sec, min, hour, mday, month, year, 0, 0, -1))
end

# Returns the modification time of f as seconds since epoch.
function mtime(f::Union{ReadableFile, WritableFile})
    _mtime(f.dostime, f.dosdate)
end

"Load a little endian `UInt32` from a `UInt8` vector `b` starting from index `i`"
function getindex_u32le(b::Vector{UInt8}, i)
    b0 = UInt32(b[i])
    b1 = UInt32(b[i + 1])
    b2 = UInt32(b[i + 2])
    b3 = UInt32(b[i + 3])
    return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
end

function _find_sigoffset(io::IO, sig::UInt32)
    seekend(io)
    filesize = position(io)
    offset = nothing

    # Look for end of central directory locator in the last 1KB.
    # Failing that, look for it in the last 65KB.
    for guess in [1024, 65*1024]
        if offset !== nothing
            break
        end
        k = min(filesize, guess)
        n = filesize-k
        seek(io, n)
        b = read!(io, Array{UInt8}(undef, k))
        for i in k-3:-1:1
            if getindex_u32le(b, i) == sig
                offset = n+i-1
                break
            end
        end
    end
    if offset === nothing
        error("failed to find end of centeral directory record")
    end
    offset
end

_find_enddiroffset(io::IO) = _find_sigoffset(io, _EndCentralDirSig)
_find_zip64_enddirlocoffset(io::IO) = _find_sigoffset(io, _Zip64EndCentralLocSig)

function _find_zip64_enddiroffset(io::IO, locoffset::Integer)
	seek(io, locoffset)
	if readle(io, UInt32) != _Zip64EndCentralLocSig
		error("internal error")
	end
	skip(io, 4)
	readle(io, UInt64) #the offset of the z64ecd
end
function _find_zip64_diroffset(io::IO, enddiroffset::Integer)
	seek(io, enddiroffset)
	if readle(io, UInt32) != _Zip64EndCentralDirSig
		error("internal error")
	end
	skip(io, 8+2+2+4+4+8)
	nfiles = readle(io, UInt64)
	skip(io, 8) #skip size of central directory
	offset = readle(io, UInt64)
	offset, nfiles
end
function _find_diroffset(io::IO, enddiroffset::Integer)
	seek(io, enddiroffset)
	if readle(io, UInt32) != _EndCentralDirSig
		error("internal error")
	end
	skip(io, 2+2+2)
	nfiles = read(io, UInt16)
	skip(io, 4)
	offset = readle(io, UInt32)
	commentlen = readle(io, UInt16)
    comment = utf8_validate(read!(io, Array{UInt8}(undef, commentlen)))
	if nfiles == 0xFFFF || offset == 0xFFFFFFFF
		dirloc = _find_zip64_enddirlocoffset(io)
		z64enddiroffset = _find_zip64_enddiroffset(io::IO, dirloc)
		offset, nfiles = _find_zip64_diroffset(io, z64enddiroffset)
	end
	offset, nfiles, comment
end


function _getfiles(io::IO, diroffset::Integer, nfiles::Integer)
    seek(io, diroffset)
    files = Vector{ReadableFile}(undef, nfiles)
    for i in 1:nfiles
        if readle(io, UInt32) != _CentralDirSig
            error("invalid file header")
        end
        skip(io, 2+2)
        flag = readle(io, UInt16)
        if (flag & (1<<0)) != 0
            error("encryption not supported")
        end

        method = readle(io, UInt16)
        dostime = readle(io, UInt16)
        dosdate = readle(io, UInt16)
        crc32 = readle(io, UInt32)
        compsize = readle(io, UInt32)
        uncompsize = readle(io, UInt32)
        namelen = readle(io, UInt16)
        extralen = readle(io, UInt16)
        commentlen = readle(io, UInt16)
        skip(io, 2+2+4)
        offset = readle(io, UInt32)
        name = utf8_validate(read!(io, Array{UInt8}(undef, namelen)))
        extra = read!(io, Array{UInt8}(undef, extralen))
        extrabuf = IOBuffer(extra)
        while !eof(extrabuf)
            extraid = readle(extrabuf, UInt16)
            extrasz = readle(extrabuf, UInt16)
            if extraid == 0x0001
                if uncompsize == 0xFFFFFFFF
                    uncompsize = readle(extrabuf, UInt64)
                end
                if compsize == 0xFFFFFFFF
                    compsize = readle(extrabuf, UInt64)
                end
                if offset == 0xFFFFFFFF
                    offset = readle(extrabuf, UInt64)
                end
            else
                skip(extrabuf, extrasz)
            end

        end
        skip(io, commentlen)
        files[i] = ReadableFile(io, name, method, dostime, dosdate,
            crc32, compsize, uncompsize, offset)
    end
    files
end
# Close the underlying IO instance if it was opened by Reader.
# User is still responsible for closing the IO instance if it was passed to Reader.
function close(r::Reader)
    if r._close_io
        close(r._io)
    end
end

# Finish writing the ZIP file and close the underlying IO instance if it was opened by Writer.
# User is still responsible for closing the IO instance if it was passed to Writer.
function close(w::Writer)
    if w._closed
        return
    end
    w._closed = true
    flush(w)
    if w._close_io
        close(w._io)
    end
end

# Write central directory record and flush underlying IO instance.
function flush(w::Writer)
    if w._current !== nothing
        close(w._current)
        w._current = nothing
    end

    cdpos = position(w._io)
    cdsize = 0

    # write central directory record
    for f in w.files
        _writele(w._io, UInt32(_CentralDirSig))
        _writele(w._io, UInt16(_ZipVersion))
        _writele(w._io, UInt16(_ZipVersion))
        _writele(w._io, UInt16(0))
        _writele(w._io, UInt16(f.method))
        _writele(w._io, UInt16(f.dostime))
        _writele(w._io, UInt16(f.dosdate))
        _writele(w._io, UInt32(f.crc32))
        _writele(w._io, UInt32(f.compressedsize))
        _writele(w._io, UInt32(f.uncompressedsize))
        b = Vector{UInt8}(codeunits(f.name))
        _writele(w._io, UInt16(length(b)))
        _writele(w._io, UInt16(0))
        _writele(w._io, UInt16(0))
        _writele(w._io, UInt16(0))
        _writele(w._io, UInt16(0))
        _writele(w._io, UInt32(0))
        _writele(w._io, UInt32(f._offset))
        _writele(w._io, b)
        cdsize += 46+length(b)
    end

    # write end of central directory
    _writele(w._io, UInt32(_EndCentralDirSig))
    _writele(w._io, UInt16(0))
    _writele(w._io, UInt16(0))
    _writele(w._io, UInt16(length(w.files)))
    _writele(w._io, UInt16(length(w.files)))
    _writele(w._io, UInt32(cdsize))
    _writele(w._io, UInt32(cdpos))
    _writele(w._io, UInt16(0))

    flush(w._io)

    # Seek to the beginning of central directory so that appending
    # more files will overwrite it.
    seek(w._io, cdpos)

    return
end

# Flush the file f into the ZIP file.
function close(f::WritableFile)
    if f._closed
        return
    end
    f._closed = true

    if f.method == Deflate
        close(f._zio)
    end
    f.compressedsize = position(f)

    # fill in local file header fillers
    pos = position(f._io)
    seek(f._io, f._offset+14)   # seek to CRC-32
    _writele(f._io, UInt32(f.crc32))
    _writele(f._io, UInt32(f.compressedsize))
    _writele(f._io, UInt32(f.uncompressedsize))

    # Seek to the end of file `f`.  Note that we can't use
    # `seekend(f._io)` because the end position of the physical zip
    # file can be larger than the position `pos` of the end of the
    # file `f` if `flush(::Writer)` has been called before and the
    # size of this file `f` is smaller than the central directory
    # record.
    seek(f._io, pos)
end

# A no-op provided for completeness.
function close(f::ReadableFile)
    nothing
end

"create underlying Zlib reader if doesn't exist"
function ensure_zio!(f::ReadableFile)
    f._datapos >= 0 && return

    seek(f._io, f._offset)
    if readle(f._io, UInt32) != _LocalFileHdrSig
        error("invalid file header")
    end
    skip(f._io, 2+2+2+2+2+4+4+4)
    filelen = readle(f._io, UInt16)
    extralen = readle(f._io, UInt16)
    skip(f._io, filelen+extralen)
    if f.method == Deflate
        f._zio = Zlib.Reader(f._io, true)
    elseif f.method == Store
        f._zio = f._io
    end
    f._datapos = position(f._io)
end

"advance io position state and crc32 checksum, checking it at eof"
function update_reader!(f::ReadableFile, data::Array{UInt8})
    f._zpos = position(f._io) - f._datapos
    f._pos += length(data)
    f._currentcrc32 = Zlib.crc32(data, f._currentcrc32)

    if eof(f)
        if f.method == Deflate
            close(f._zio)
        end
        if  f._currentcrc32 != f.crc32
            error("crc32 do not match")
        end
    end
end
update_reader!(f::ReadableFile, data::UInt8) = update_reader!(f, [data])


# Read data into a. Throws EOFError if a cannot be filled in completely.
read(f::ReadableFile, a::Array{T}) where T = read!(f, Array{T}(undef, size(a)))

read!(f::ReadableFile, a::Array{UInt8}) = _read(f, a)
read!(f::ReadableFile, a::Array{T}) where T = _read(f, a)

function read(f::ReadableFile, ::Type{UInt8})
    ensure_zio!(f)
    seek(f._io, f._datapos+f._zpos)
    byte = read(f._zio, UInt8)
    update_reader!(f, byte)
    byte
end

function Base.unsafe_read(f::ReadableFile, p::Ptr{UInt8}, n::UInt)
    ensure_zio!(f)
    seek(f._io, f._datapos+f._zpos)
    b = unsafe_wrap(Array{UInt8, 1}, p, n)
    read!(f._zio, b)
    update_reader!(f, b)
    nothing
end

function read(f::ReadableFile, nb::Integer=typemax(Int))
    ensure_zio!(f)

    nb = min(nb, f.uncompressedsize - f._pos)
    b = Vector{UInt8}(undef, nb)
    seek(f._io, f._datapos+f._zpos)
    read!(f._zio, b)
    update_reader!(f, b)

    return b
end

function _read(f::ReadableFile, a::Array{T}) where T
    ensure_zio!(f)

    if eof(f) || f._pos+length(a)*sizeof(T) > f.uncompressedsize
        throw(EOFError())
    end

    seek(f._io, f._datapos+f._zpos)
    b = unsafe_wrap(Array{UInt8, 1}, reinterpret(Ptr{UInt8}, pointer(a)), sizeof(a))
    GC.@preserve a begin
        read!(f._zio, b)
        update_reader!(f, b)
    end

    return a
end

# Returns true if and only if we have reached the end of file f.
function eof(f::ReadableFile)
    f._pos >= f.uncompressedsize
end

"""
    addfile(w::Writer, name::AbstractString; method::Integer=Store, mtime::Float64=-1.0)

Add a new file named name into the ZIP file writer w, and return the
WritableFile for the new file. We don't allow concurrrent writes,
thus the file previously added using this function will be closed.

Method specifies the compression method that will be used (Store for
uncompressed or Deflate for compressed).

Mtime is the modification time of the file.
"""
function addfile(w::Writer, name::AbstractString; method::Integer=Store, mtime::Float64=-1.0)
    if w._current !== nothing
        close(w._current)
        w._current = nothing
    end


    if mtime < 0
        mtime = time()
    end
    dostime, dosdate = _msdostime(mtime)
    f = WritableFile(w._io, name, UInt16(method), dostime, dosdate,
        UInt32(0), UInt32(0), UInt32(0), UInt32(position(w._io)),
        Int64(-1), w._io, false)

    # Write local file header. Missing entries will be filled in later.
    _writele(w._io, UInt32(_LocalFileHdrSig))
    _writele(w._io, UInt16(_ZipVersion))
    _writele(w._io, UInt16(0))
    _writele(w._io, UInt16(f.method))
    _writele(w._io, UInt16(f.dostime))
    _writele(w._io, UInt16(f.dosdate))
    _writele(w._io, UInt32(f.crc32))    # filler
    _writele(w._io, UInt32(f.compressedsize))   # filler
    _writele(w._io, UInt32(f.uncompressedsize)) # filler
    b = Vector{UInt8}(codeunits(f.name))
    _writele(w._io, UInt16(length(b)))
    _writele(w._io, UInt16(0))
    _writele(w._io, b)

    f._datapos = position(w._io)
    if f.method == Deflate
        f._zio = Zlib.Writer(f._io, true)
    end
    w.files = [w.files; f]
    w._current = f
    w._current
end

# Returns the current position in file f.
function position(f::WritableFile)
    position(f._io) - f._datapos
end

# Returns the current position in file f.
function position(f::ReadableFile)
    f._pos
end

function Base.seek(io::ReadableFile, n::Integer)
    # It's not possible to seek the compressed stream without an extra
    # compression index, so only support seeking to the start.
    n == 0 || throw(ArgumentError("Cannot efficiently seek zip stream to nonzero offset $n"))
    io._datapos = -1
    io._currentcrc32 = 0
    io._pos = 0
    io._zpos = 0
    return io
end

# Needed for use as `src` in `write(dst::IO, src::IO)`.
Base.readavailable(io::ZipFile.ReadableFile) = read(io)

# Write nb elements located at p into f.
function unsafe_write(f::WritableFile, p::Ptr{UInt8}, nb::UInt)
    # zlib doesn't like 0 length writes
    if nb == 0
        return 0
    end

    n = unsafe_write(f._zio, p, nb)
    if n != nb
        error("short write")
    end

    f.crc32 = Zlib.crc32(unsafe_wrap(Array, p, nb), f.crc32)
    f.uncompressedsize += n
    n
end

end # module
