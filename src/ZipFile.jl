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
# 	dir = ZipFile.Writer("example.zip");
# 	f = ZipFile.addfile(dir, "hello.txt");
# 	write(f, "hello world!\n");
# 	f = ZipFile.addfile(dir, "julia.txt", method=ZipFile.Deflate);
# 	write(f, "Julia\n"^5);
# 	close(dir)
# 
# Read and print out the contents of a ZIP file::
# 
# 	dir = ZipFile.Reader("example.zip");
# 	for f in dir.files
# 		println("Filename: $(f.name)")
# 		write(readall(f));
# 	end
# 	close(dir)
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
module ZipFile

import Base: read, eof, write, close, mtime, position, show
import Zlib

export read, eof, write, close, mtime, position, show

# TODO: ZIP64 support, data descriptor support

const _LocalFileHdrSig   = 0x04034b50
const _CentralDirSig     = 0x02014b50
const _EndCentralDirSig  = 0x06054b50
const _ZipVersion = 20
const Store = 0		# Compression method that does no compression
const Deflate = 8	# Deflate compression method
const _Method2Str = [Store => "Store", Deflate => "Deflate"]

type ReadableFile <: IO
	io :: IO
	name :: String
	method :: Uint16
	dostime :: Uint16
	dosdate :: Uint16
	crc32 :: Uint32
	compressedsize :: Uint32
	uncompressedsize :: Uint32
	offset :: Uint32
	_datapos :: Int64   # position where data begins
	_zio :: IO          # compression IO

	_currentcrc32 :: Uint32
	_pos :: Int64       # current position in uncompressed data
	_zpos :: Int64      # current position in compressed data
	
	function ReadableFile(io::IO, name::String, method::Uint16, dostime::Uint16,
			dosdate::Uint16, crc32::Uint32, compressedsize::Uint32,
			uncompressedsize::Uint32, offset::Uint32)
		if method != Store && method != Deflate
			error("unknown compression method $method")
		end
		new(io, name, method, dostime, dosdate, crc32,
			compressedsize, uncompressedsize, offset, -1, io, 0, 0, 0)
	end
end

type Reader
	io :: IO
	files :: Vector{ReadableFile} # ZIP file entries that be read concurrently
	comment :: String             # ZIP file comment
	
	Reader(io::IO, files::Vector{ReadableFile}, comment::String) =
		(x = new(io, files, comment); finalizer(x, close); x)
end

# Read a ZIP file from io.
function Reader(io::IO)
	endoff = _find_enddiroffset(io)
	diroff, nfiles, comment = _find_diroffset(io, endoff)
	files = _getfiles(io, diroff, nfiles)
	Reader(io, files, comment)
end

# Read a ZIP file from the file named filename.
function Reader(filename::String)
	Reader(Base.open(filename))
end

type WritableFile <: IO
	io :: IO
	name :: String
	method :: Uint16
	dostime :: Uint16
	dosdate :: Uint16
	crc32 :: Uint32
	compressedsize :: Uint32
	uncompressedsize :: Uint32
	offset :: Uint32
	_datapos :: Int64   # position where data begins
	_zio :: IO          # compression IO
	
	closed :: Bool
	
	function WritableFile(io::IO, name::String, method::Uint16, dostime::Uint16,
			dosdate::Uint16, crc32::Uint32, compressedsize::Uint32,
			uncompressedsize::Uint32, offset::Uint32, _datapos::Int64,
			_zio::IO, closed::Bool)
		if method != Store && method != Deflate
			error("unknown compression method $method")
		end
		f = new(io, name, method, dostime, dosdate, crc32,
			compressedsize, uncompressedsize, offset, _datapos, _zio, closed)
		finalizer(f, close)
		f
	end
end

type Writer
	io :: IO
	files :: Vector{WritableFile}
	current :: Union(WritableFile, Nothing)
	closed :: Bool
	
	Writer(io::IO, files::Vector{WritableFile},
		current::Union(WritableFile, Nothing), closed::Bool) =
		(x = new(io, files, current, closed); finalizer(x, close); x)
end

# Create a new ZIP file that will be written to io.
function Writer(io::IO)
	Writer(io, WritableFile[], nothing, false)
end

# Create a new ZIP file that will be written to the file named filename.
function Writer(filename::String)
	Writer(Base.open(filename, "w"))
end

# Print out a summary of f in a human-readable format.
function show(io::IO, f::Union(ReadableFile, WritableFile))
	print("$(string(typeof(f)))(name=$(f.name), method=$(_Method2Str[f.method]), uncompresssedsize=$(f.uncompressedsize), compressedsize=$(f.compressedsize), mtime=$(mtime(f)))")
end

# Print out a summary of rw in a human-readable format.
function show(io::IO, rw::Union(Reader, Writer))
	println("$(string(typeof(rw))) for $(rw.io) containing $(length(rw.files)) files:\n")
	@printf("%16s %-7s %-16s %s\n", "uncompressedsize", "method", "mtime", "name")
	println("-"^(16+1+7+1+16+1+4))
	for f in rw.files
		@printf("%16d %-7s %-16s %s\n",
			f.uncompressedsize, _Method2Str[f.method],
			strftime("%Y-%m-%d %H-%M", mtime(f)), f.name)
	end
end

include("deprecated.jl")
include("iojunk.jl")

readle(io::IO, ::Type{Uint32}) = htol(read(io, Uint32))
readle(io::IO, ::Type{Uint16}) = htol(read(io, Uint16))

function _writele(io::IO, x::Vector{Uint8})
	n = write(io, x)
	if n != length(x)
		error("short write")
	end
	n
end

_writele(io::IO, x::Uint16) = _writele(io, reinterpret(Uint8, [htol(x)]))
_writele(io::IO, x::Uint32) = _writele(io, reinterpret(Uint8, [htol(x)]))

# For MS-DOS time/date format, see:
# http://msdn.microsoft.com/en-us/library/ms724247(v=VS.85).aspx

# Convert seconds since epoch to MS-DOS time/date, which has
# a resolution of 2 seconds.
function _msdostime(secs::Float64)
	t = TmStruct(secs)
	dostime = uint16((t.hour<<11) | (t.min<<5) | div(t.sec, 2))
	dosdate = uint16(((t.year+1900-1980)<<9) | ((t.month+1)<<5) | t.mday)
	dostime, dosdate
end

# Convert MS-DOS time/date to seconds since epoch
function _mtime(dostime::Uint16, dosdate::Uint16)
	sec = 2*(dostime & 0x1f)
	min = (dostime>>5) & 0x3f
	hour = dostime>>11
	mday = dosdate & 0x1f
	month = ((dosdate>>5) & 0xf) - 1
	year = (dosdate>>9) + 1980 - 1900
	time(TmStruct(sec, min, hour, mday, month, year, 0, 0, -1))
end

# Returns the modification time of f.
function mtime(f::Union(ReadableFile, WritableFile))
	_mtime(f.dostime, f.dosdate)
end

function _find_enddiroffset(io::IO)
	seekend(io)
	filesize = position(io)
	offset = None

	# Look for end of central directory locator in the last 1KB.
	# Failing that, look for it in the last 65KB.
	for guess in [1024, 65*1024]
		if ~is(offset, None)
			break
		end
		k = min(filesize, guess)
		n = filesize-k
		seek(io, n)
		b = read(io, Uint8, k)
		for i in 1:k-3
			if htol(reinterpret(Uint32, b[i:i+3]))[1] == _EndCentralDirSig
				offset = n+i-1
				break
			end
		end
	end
	if is(offset, None)
		error("failed to find end of centeral directory record")
	end
	offset
end

function _find_diroffset(io::IO, enddiroffset::Integer)
	seek(io, enddiroffset)
	if readle(io, Uint32) != _EndCentralDirSig
		error("internal error")
	end
	skip(io, 2+2+2)
	nfiles = read(io, Uint16)
	skip(io, 4)
	offset = readle(io, Uint32)
	commentlen = readle(io, Uint16)
	comment = utf8(read(io, Uint8, commentlen))
	offset, nfiles, comment
end

function _getfiles(io::IO, diroffset::Integer, nfiles::Integer)
	seek(io, diroffset)
	files = Array(ReadableFile, nfiles)
	for i in 1:nfiles
		if readle(io, Uint32) != _CentralDirSig
			error("invalid file header")
		end
		skip(io, 2+2)
		flag = readle(io, Uint16)
		if (flag & (1<<0)) != 0
			error("encryption not supported")
		end
		if (flag & (1<<3)) != 0
			error("data descriptor not supported")
		end
		method = readle(io, Uint16)
		dostime = readle(io, Uint16)
		dosdate = readle(io, Uint16)
		crc32 = readle(io, Uint32)
		compsize = readle(io, Uint32)
		uncompsize = readle(io, Uint32)
		namelen = readle(io, Uint16)
		extralen = readle(io, Uint16)
		commentlen = readle(io, Uint16)
		skip(io, 2+2+4)
		offset = readle(io, Uint32)
		name = utf8(read(io, Uint8, namelen))
		skip(io, extralen+commentlen)
		files[i] = ReadableFile(io, name, method, dostime, dosdate,
			crc32, compsize, uncompsize, offset)
	end
	files
end

# Close the underlying IO instance.
function close(dir::Reader)
	close(dir.io)
end

# Flush output and close the underlying IO instance.
function close(w::Writer)
	if w.closed
		return
	end
	w.closed = true
	
	if !is(w.current, nothing)
		close(w.current)
		w.current = nothing
	end

	cdpos = position(w.io)
	cdsize = 0
	
	# write central directory record
	for f in w.files
		_writele(w.io, uint32(_CentralDirSig))
		_writele(w.io, uint16(_ZipVersion))
		_writele(w.io, uint16(_ZipVersion))
		_writele(w.io, uint16(0))
		_writele(w.io, uint16(f.method))
		_writele(w.io, uint16(f.dostime))
		_writele(w.io, uint16(f.dosdate))
		_writele(w.io, uint32(f.crc32))
		_writele(w.io, uint32(f.compressedsize))
		_writele(w.io, uint32(f.uncompressedsize))
		b = convert(Vector{Uint8}, f.name)
		_writele(w.io, uint16(length(b)))
		_writele(w.io, uint16(0))
		_writele(w.io, uint16(0))
		_writele(w.io, uint16(0))
		_writele(w.io, uint16(0))
		_writele(w.io, uint32(0))
		_writele(w.io, uint32(f.offset))
		_writele(w.io, b)
		cdsize += 46+length(b)
	end
	
	# write end of central directory
	_writele(w.io, uint32(_EndCentralDirSig))
	_writele(w.io, uint16(0))
	_writele(w.io, uint16(0))
	_writele(w.io, uint16(length(w.files)))
	_writele(w.io, uint16(length(w.files)))
	_writele(w.io, uint32(cdsize))
	_writele(w.io, uint32(cdpos))
	_writele(w.io, uint16(0))
	
	close(w.io)
end

# Flush the file f into the ZIP file.
function close(f::WritableFile)
	if f.closed
		return
	end
	f.closed = true
	
	if f.method == Deflate
		close(f._zio)
	end
	f.compressedsize = position(f)
	
	# fill in local file header fillers
	seek(f.io, f.offset+14)	# seek to CRC-32
	_writele(f.io, uint32(f.crc32))
	_writele(f.io, uint32(f.compressedsize))
	_writele(f.io, uint32(f.uncompressedsize))
	seekend(f.io)
end

# A no-op provided for completeness.
function close(f::ReadableFile)
	nothing
end

# Read data into a. Throws EOFError if a cannot be filled in completely.
function read{T}(f::ReadableFile, a::Array{T})
	if !isbits(T)
		return invoke(read, (IO, Array), s, a)
	end
	
	if f._datapos < 0
		seek(f.io, f.offset)
		if readle(f.io, Uint32) != _LocalFileHdrSig
			error("invalid file header")
		end
		skip(f.io, 2+2+2+2+2+4+4+4)
		filelen = readle(f.io, Uint16)
		extralen = readle(f.io, Uint16)
		skip(f.io, filelen+extralen)
		if f.method == Deflate
			f._zio = Zlib.Reader(f.io, true)
		elseif f.method == Store
			f._zio = f.io
		end
		f._datapos = position(f.io)
	end
	
	if eof(f) || f._pos+length(a)*sizeof(T) > f.uncompressedsize
		throw(EOFError())
	end
	
	seek(f.io, f._datapos+f._zpos)
	b = reinterpret(Uint8, reshape(a, length(a)))
	read(f._zio, b)
	f._zpos = position(f.io) - f._datapos
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

# Reaturn true if and only if we have reached the end of file f.
function eof(f::ReadableFile)
	f._pos >= f.uncompressedsize
end

# Add a new file named name into the ZIP file writer w, and return the
# WritableFile for the new file. We don't allow concurrrent writes,
# thus the file previously added using this function will be closed.
# Method names the compression method that will be used, and mtime is the
# modification time of the file.
function addfile(w::Writer, name::String; method::Integer=Store, mtime::Float64=-1.0)
	if !is(w.current, nothing)
		close(w.current)
		w.current = nothing
	end
	
	if mtime < 0
		mtime = time()
	end
	dostime, dosdate = _msdostime(mtime)
	f = WritableFile(w.io, name, uint16(method), dostime, dosdate,
		uint32(0), uint32(0), uint32(0), uint32(position(w.io)),
		int64(-1), w.io, false)
	
	# Write local file header. Missing entries will be filled in later.
	_writele(w.io, uint32(_LocalFileHdrSig))
	_writele(w.io, uint16(_ZipVersion))
	_writele(w.io, uint16(0))
	_writele(w.io, uint16(f.method))
	_writele(w.io, uint16(f.dostime))
	_writele(w.io, uint16(f.dosdate))
	_writele(w.io, uint32(f.crc32))	# filler
	_writele(w.io, uint32(f.compressedsize))	# filler
	_writele(w.io, uint32(f.uncompressedsize))	# filler
	b = convert(Vector{Uint8}, f.name)
	_writele(w.io, uint16(length(b)))
	_writele(w.io, uint16(0))
	_writele(w.io, b)

	f._datapos = position(w.io)
	if f.method == Deflate
		f._zio = Zlib.Writer(f.io, false, true)
	end
	w.files = [w.files, f]
	w.current = f
	w.current
end

# Returns the current position in file f.
function position(f::WritableFile)
	position(f.io) - f._datapos
end

# Returns the current position in file f.
function position(f::ReadableFile)
	f._pos
end

# Write nb elements located a p into f.
function write(f::WritableFile, p::Ptr, nb::Integer)
	n = write(f._zio, p, nb)
	if n != nb
		error("short write")
	end
	
	a = pointer_to_array(p, nb)
	b = reinterpret(Uint8, reshape(a, length(a)))
	f.crc32 = Zlib.crc32(b, f.crc32)
	f.uncompressedsize += n
	n
end

end # module
