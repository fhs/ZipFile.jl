# A Julia package for reading/writing ZIP archive files
#
# This package provides support for reading and writing ZIP archives in Julia.
# Install it via the Julia package manager using ``Pkg.add("ZipFile")``.
#
# The ZIP file format is described in
# http://www.pkware.com/documents/casestudies/APPNOTE.TXT
#
# Example
# -------
#
# Write a new ZIP file::
#
# 	using ZipFile
#
# 	w = ZipFile.Writer("example.zip");
# 	f = ZipFile.addfile(w, "hello.txt");
# 	write(f, "hello world!\n");
# 	f = ZipFile.addfile(w, "julia.txt", method=ZipFile.Deflate);
# 	write(f, "Julia\n"^5);
# 	close(w)
#
# Read and print out the contents of a ZIP file::
#
# 	r = ZipFile.Reader("example.zip");
# 	for f in r.files
# 		println("Filename: $(f.name)")
# 		write(readstring(f));
# 	end
# 	close(r)
#
# Output::
#
# 	Filename: hello.txt
# 	hello world!
# 	Filename: julia.txt
# 	Julia
# 	Julia
# 	Julia
# 	Julia
# 	Julia
#
isdefined(Base, :__precompile__) && __precompile__()
module ZipFile

import Base: read, eof, write, close, mtime, position, show
using Compat
import Compat: unsafe_write

export read, eof, write, close, mtime, position, show

if !isdefined(:read!)
    read! = read
end

include("Zlib.jl")
import .Zlib

# TODO: ZIP64 support, data descriptor support

const _LocalFileHdrSig   = 0x04034b50
const _CentralDirSig     = 0x02014b50
const _EndCentralDirSig  = 0x06054b50
const _ZipVersion = 20
const Store = @compat UInt16(0)   # Compression method that does no compression
const Deflate = @compat UInt16(8) # Deflate compression method
const _Method2Str = @compat Dict{UInt16,Compat.UTF8String}(Store => "Store", Deflate => "Deflate")

type ReadableFile <: IO
	_io :: IO
	name :: Compat.UTF8String   # filename
	method :: UInt16            # compression method
	dostime :: UInt16           # modification time in MS-DOS format
	dosdate :: UInt16           # modification date in MS-DOS format
	crc32 :: UInt32             # CRC32 of uncompressed data
	compressedsize :: UInt32    # file size after compression
	uncompressedsize :: UInt32  # size of uncompressed file
	_offset :: UInt32
	_datapos :: Int64   # position where data begins
	_zio :: IO          # compression IO

	_currentcrc32 :: UInt32
	_pos :: Int64       # current position in uncompressed data
	_zpos :: Int64      # current position in compressed data

	function ReadableFile(io::IO, name::AbstractString, method::UInt16, dostime::UInt16,
			dosdate::UInt16, crc32::UInt32, compressedsize::UInt32,
			uncompressedsize::UInt32, _offset::UInt32)
		if method != Store && method != Deflate
			error("unknown compression method $method")
		end
		new(io, name, method, dostime, dosdate, crc32,
			compressedsize, uncompressedsize, _offset, -1, io, 0, 0, 0)
	end
end

type Reader
	_io :: IO
	_close_io :: Bool
	files :: Vector{ReadableFile} # ZIP file entries that can be read concurrently
	comment :: Compat.UTF8String  # ZIP file comment

	function Reader(io::IO, close_io::Bool)
		endoff = _find_enddiroffset(io)
		diroff, nfiles, comment = _find_diroffset(io, endoff)
		files = _getfiles(io, diroff, nfiles)
		x = new(io, close_io, files, comment)
		finalizer(x, close)
		x
	end
end

# Read a ZIP file from io.
function Reader(io::IO)
	Reader(io, false)
end

# Read a ZIP file from the file named filename.
function Reader(filename::AbstractString)
	Reader(Base.open(filename), true)
end

type WritableFile <: IO
	_io :: IO
	name :: Compat.UTF8String   # filename
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
		finalizer(f, close)
		f
	end
end

type Writer
	_io :: IO
	_close_io :: Bool
	files :: Vector{WritableFile} # files (being) written
	_current :: (@compat Union{WritableFile, Void})
	_closed :: Bool

	function Writer(io::IO, close_io::Bool)
		x = new(io, close_io, WritableFile[], nothing, false)
		finalizer(x, close)
		x
	end
end

# Create a new ZIP file that will be written to io.
function Writer(io::IO)
	Writer(io, false)
end

# Create a new ZIP file that will be written to the file named filename.
function Writer(filename::AbstractString)
	Writer(Base.open(filename, "w"), true)
end

# Print out a summary of f in a human-readable format.
function show(io::IO, f::@compat Union{ReadableFile, WritableFile})
	print(io, "$(string(typeof(f)))(name=$(f.name), method=$(_Method2Str[f.method]), uncompresssedsize=$(f.uncompressedsize), compressedsize=$(f.compressedsize), mtime=$(mtime(f)))")
end

# Print out a summary of rw in a human-readable format.
function show(io::IO, rw::@compat Union{Reader, Writer})
	println(io, "$(string(typeof(rw))) for $(rw._io) containing $(length(rw.files)) files:\n")
	@printf(io, "%16s %-7s %-16s %s\n", "uncompressedsize", "method", "mtime", "name")
	println(io, "-"^(16+1+7+1+16+1+4))
	for f in rw.files
		ftime = @compat Libc.strftime("%Y-%m-%d %H-%M", mtime(f))
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

readle(io::IO, ::Type{UInt32}) = htol(read(io, UInt32))
readle(io::IO, ::Type{UInt16}) = htol(read(io, UInt16))

function _writele(io::IO, x::Vector{UInt8})
	n = write(io, x)
	if n != length(x)
		error("short write")
	end
	n
end

_writele(io::IO, x::UInt16) = _writele(io, reinterpret(UInt8, [htol(x)]))
_writele(io::IO, x::UInt32) = _writele(io, reinterpret(UInt8, [htol(x)]))

# For MS-DOS time/date format, see:
# http://msdn.microsoft.com/en-us/library/ms724247(v=VS.85).aspx

# Convert seconds since epoch to MS-DOS time/date, which has
# a resolution of 2 seconds.
function _msdostime(secs::Float64)
	t = @compat Libc.TmStruct(secs)
	dostime = @compat UInt16((t.hour<<11) | (t.min<<5) | div(t.sec, 2))
	dosdate = @compat UInt16(((t.year+1900-1980)<<9) | ((t.month+1)<<5) | t.mday)
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
	time(@compat Libc.TmStruct(sec, min, hour, mday, month, year, 0, 0, -1))
end

# Returns the modification time of f as seconds since epoch.
function mtime(f::@compat Union{ReadableFile, WritableFile})
	_mtime(f.dostime, f.dosdate)
end

function _find_enddiroffset(io::IO)
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
		b = read(io, UInt8, k)
		for i in 1:k-3
			if htol(reinterpret(UInt32, b[i:i+3]))[1] == _EndCentralDirSig
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
	comment = utf8_validate(read(io, UInt8, commentlen))
	offset, nfiles, comment
end

function _getfiles(io::IO, diroffset::Integer, nfiles::Integer)
	seek(io, diroffset)
	files = Vector{ReadableFile}(nfiles)
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
		name = utf8_validate(read(io, UInt8, namelen))
		skip(io, extralen+commentlen)
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

	if w._current !== nothing
		close(w._current)
		w._current = nothing
	end

	cdpos = position(w._io)
	cdsize = 0

	# write central directory record
	for f in w.files
		_writele(w._io, @compat UInt32(_CentralDirSig))
		_writele(w._io, @compat UInt16(_ZipVersion))
		_writele(w._io, @compat UInt16(_ZipVersion))
		_writele(w._io, @compat UInt16(0))
		_writele(w._io, @compat UInt16(f.method))
		_writele(w._io, @compat UInt16(f.dostime))
		_writele(w._io, @compat UInt16(f.dosdate))
		_writele(w._io, @compat UInt32(f.crc32))
		_writele(w._io, @compat UInt32(f.compressedsize))
		_writele(w._io, @compat UInt32(f.uncompressedsize))
		b = convert(Vector{UInt8}, f.name)
		_writele(w._io, @compat UInt16(length(b)))
		_writele(w._io, @compat UInt16(0))
		_writele(w._io, @compat UInt16(0))
		_writele(w._io, @compat UInt16(0))
		_writele(w._io, @compat UInt16(0))
		_writele(w._io, @compat UInt32(0))
		_writele(w._io, @compat UInt32(f._offset))
		_writele(w._io, b)
		cdsize += 46+length(b)
	end

	# write end of central directory
	_writele(w._io, @compat UInt32(_EndCentralDirSig))
	_writele(w._io, @compat UInt16(0))
	_writele(w._io, @compat UInt16(0))
	_writele(w._io, @compat UInt16(length(w.files)))
	_writele(w._io, @compat UInt16(length(w.files)))
	_writele(w._io, @compat UInt32(cdsize))
	_writele(w._io, @compat UInt32(cdpos))
	_writele(w._io, @compat UInt16(0))

	if w._close_io
		close(w._io)
	end
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
	seek(f._io, f._offset+14)	# seek to CRC-32
	_writele(f._io, @compat UInt32(f.crc32))
	_writele(f._io, @compat UInt32(f.compressedsize))
	_writele(f._io, @compat UInt32(f.uncompressedsize))
	seekend(f._io)
end

# A no-op provided for completeness.
function close(f::ReadableFile)
	nothing
end

# Read data into a. Throws EOFError if a cannot be filled in completely.
function read{T}(f::ReadableFile, a::Array{T})
	if !isbits(T)
		return @compat invoke(read, Tuple{IO,Array}, s, a)
	end

	if f._datapos < 0
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

	if eof(f) || f._pos+length(a)*sizeof(T) > f.uncompressedsize
		throw(EOFError())
	end

	seek(f._io, f._datapos+f._zpos)
	b = reinterpret(UInt8, reshape(a, length(a)))
	read!(f._zio, b)
	f._zpos = position(f._io) - f._datapos
	f._pos += length(b)
	f._currentcrc32 = Zlib.crc32(b, f._currentcrc32)

	if eof(f)
		if f.method == Deflate
			close(f._zio)
		end
		if  f._currentcrc32 != f.crc32
			error("crc32 do not match")
		end
	end
	a
end

# Returns true if and only if we have reached the end of file f.
function eof(f::ReadableFile)
	f._pos >= f.uncompressedsize
end

# Add a new file named name into the ZIP file writer w, and return the
# WritableFile for the new file. We don't allow concurrrent writes,
# thus the file previously added using this function will be closed.
# Method specifies the compression method that will be used, and mtime is the
# modification time of the file.
function addfile(w::Writer, name::AbstractString; method::Integer=Store, mtime::Float64=-1.0)
	if w._current !== nothing
		close(w._current)
		w._current = nothing
	end

	if mtime < 0
		mtime = time()
	end
	dostime, dosdate = _msdostime(mtime)
	f = WritableFile(w._io, name, @compat(UInt16(method)), dostime, dosdate,
		@compat(UInt32(0)), @compat(UInt32(0)), @compat(UInt32(0)), @compat(UInt32(position(w._io))),
		@compat(Int64(-1)), w._io, false)

	# Write local file header. Missing entries will be filled in later.
	_writele(w._io, @compat UInt32(_LocalFileHdrSig))
	_writele(w._io, @compat UInt16(_ZipVersion))
	_writele(w._io, @compat UInt16(0))
	_writele(w._io, @compat UInt16(f.method))
	_writele(w._io, @compat UInt16(f.dostime))
	_writele(w._io, @compat UInt16(f.dosdate))
	_writele(w._io, @compat UInt32(f.crc32))	# filler
	_writele(w._io, @compat UInt32(f.compressedsize))	# filler
	_writele(w._io, @compat UInt32(f.uncompressedsize))	# filler
	b = convert(Vector{UInt8}, f.name)
	_writele(w._io, @compat UInt16(length(b)))
	_writele(w._io, @compat UInt16(0))
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
if !isdefined(Base, :unsafe_write)
	unsafe_write(f::WritableFile, p::Ptr, nb::Integer) =
		unsafe_write(f, convert(Ptr{UInt8}, p), convert(UInt, nb))
end

end # module
