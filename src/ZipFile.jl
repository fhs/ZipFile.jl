module ZipFile

# ZIP file format is described in
# http://www.pkware.com/documents/casestudies/APPNOTE.TXT

import Base: read, eof, write, close, mtime, position
import Zlib

export read, eof, write, close, mtime, position

# TODO: ZIP64 support, data descriptor support

const LocalFileHdrSig   = 0x04034b50
const CentralDirSig     = 0x02014b50
const EndCentralDirSig  = 0x06054b50
const ZipVersion = 20
const Store = 0
const Deflate = 8

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
	files :: Vector{ReadableFile}
	comment :: String
	
	Reader(io::IO, files::Vector{ReadableFile}, comment::String) =
		(x = new(io, files, comment); finalizer(x, close); x)
end

function Reader(filename::String)
	io = Base.open(filename)
	endoff = find_enddiroffset(io)
	diroff, nfiles, comment = find_diroffset(io, endoff)
	files = getfiles(io, diroff, nfiles)
	Reader(io, files, comment)
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
		wf = new(io, name, method, dostime, dosdate, crc32,
			compressedsize, uncompressedsize, offset, _datapos, _zio, closed)
		finalizer(wf, close)
		wf
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
function Writer(filename::String)
	Writer(Base.open(filename, "w"), WritableFile[], nothing, false)
end

include("deprecated.jl")
include("iojunk.jl")

readle(io::IO, ::Type{Uint32}) = htol(read(io, Uint32))
readle(io::IO, ::Type{Uint16}) = htol(read(io, Uint16))

function writele(io::IO, x::Vector{Uint8})
	n = write(io, x)
	if n != length(x)
		error("short write")
	end
	n
end

writele(io::IO, x::Uint16) = writele(io, reinterpret(Uint8, [htol(x)]))
writele(io::IO, x::Uint32) = writele(io, reinterpret(Uint8, [htol(x)]))

# For MS-DOS time/date format, see:
# http://msdn.microsoft.com/en-us/library/ms724247(v=VS.85).aspx
# Convert seconds since epoch to MS-DOS time/date, which has
# a resolution of 2 seconds.
function msdostime(secs)
	t = TmStruct(secs)
	dostime = uint16((t.hour<<11) | (t.min<<5) | div(t.sec, 2))
	dosdate = uint16(((t.year+1900-1980)<<9) | ((t.month+1)<<5) | t.mday)
	dostime, dosdate
end

# Convert MS-DOS time/date to seconds since epoch
function mtime(f::ReadableFile)
	sec = 2*(f.dostime & 0x1f)
	min = (f.dostime>>5) & 0x3f
	hour = f.dostime>>11
	mday = f.dosdate & 0x1f
	month = ((f.dosdate>>5) & 0xf) - 1
	year = (f.dosdate>>9) + 1980 - 1900
	time(TmStruct(sec, min, hour, mday, month, year, 0, 0, -1))
end

function find_enddiroffset(io::IO)
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
			if htol(reinterpret(Uint32, b[i:i+3]))[1] == EndCentralDirSig
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

function find_diroffset(io::IO, enddiroffset::Integer)
	seek(io, enddiroffset)
	if readle(io, Uint32) != EndCentralDirSig
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

function getfiles(io::IO, diroffset::Integer, nfiles::Integer)
	seek(io, diroffset)
	files = Array(ReadableFile, nfiles)
	for i in 1:nfiles
		if readle(io, Uint32) != CentralDirSig
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

close(dir::Reader) = close(dir.io)

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
		writele(w.io, uint32(CentralDirSig))
		writele(w.io, uint16(ZipVersion))
		writele(w.io, uint16(ZipVersion))
		writele(w.io, uint16(0))
		writele(w.io, uint16(f.method))
		writele(w.io, uint16(f.dostime))
		writele(w.io, uint16(f.dosdate))
		writele(w.io, uint32(f.crc32))
		writele(w.io, uint32(f.compressedsize))
		writele(w.io, uint32(f.uncompressedsize))
		b = convert(Vector{Uint8}, f.name)
		writele(w.io, uint16(length(b)))
		writele(w.io, uint16(0))
		writele(w.io, uint16(0))
		writele(w.io, uint16(0))
		writele(w.io, uint16(0))
		writele(w.io, uint32(0))
		writele(w.io, uint32(f.offset))
		writele(w.io, b)
		cdsize += 46+length(b)
	end
	
	# write end of central directory
	writele(w.io, uint32(EndCentralDirSig))
	writele(w.io, uint16(0))
	writele(w.io, uint16(0))
	writele(w.io, uint16(length(w.files)))
	writele(w.io, uint16(length(w.files)))
	writele(w.io, uint32(cdsize))
	writele(w.io, uint32(cdpos))
	writele(w.io, uint16(0))
	
	close(w.io)
end

function close(wf::WritableFile)
	if wf.closed
		return
	end
	wf.closed = true
	
	if wf.method == Deflate
		close(wf._zio)
	end
	wf.compressedsize = position(wf)
	
	# fill in local file header fillers
	seek(wf.io, wf.offset+14)	# seek to CRC-32
	writele(wf.io, uint32(wf.crc32))
	writele(wf.io, uint32(wf.compressedsize))
	writele(wf.io, uint32(wf.uncompressedsize))
	seekend(wf.io)
end

function read{T}(f::ReadableFile, a::Array{T})
	if !isbits(T)
		return invoke(read, (IO, Array), s, a)
	end
	
	if f._datapos < 0
		seek(f.io, f.offset)
		if readle(f.io, Uint32) != LocalFileHdrSig
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

function eof(f::ReadableFile)
	f._pos >= f.uncompressedsize
end

function addfile(w::Writer, name::String; method::Integer=Store, mtime::Float64=-1.0)
	if !is(w.current, nothing)
		close(w.current)
		w.current = nothing
	end
	
	if mtime < 0
		mtime = time()
	end
	dostime, dosdate = msdostime(mtime)
	f = WritableFile(w.io, name, uint16(method), dostime, dosdate,
		uint32(0), uint32(0), uint32(0), uint32(position(w.io)),
		int64(-1), w.io, false)
	
	# Write local file header. Missing entries will be filled in later.
	writele(w.io, uint32(LocalFileHdrSig))
	writele(w.io, uint16(ZipVersion))
	writele(w.io, uint16(0))
	writele(w.io, uint16(f.method))
	writele(w.io, uint16(f.dostime))
	writele(w.io, uint16(f.dosdate))
	writele(w.io, uint32(f.crc32))	# filler
	writele(w.io, uint32(f.compressedsize))	# filler
	writele(w.io, uint32(f.uncompressedsize))	# filler
	b = convert(Vector{Uint8}, f.name)
	writele(w.io, uint16(length(b)))
	writele(w.io, uint16(0))
	writele(w.io, b)

	f._datapos = position(w.io)
	if f.method == Deflate
		f._zio = Zlib.Writer(f.io, false, true)
	end
	w.files = [w.files, f]
	w.current = f
	w.current
end

function position(wf::WritableFile)
	position(wf.io) - wf._datapos
end

function write(wf::WritableFile, p::Ptr, nb::Integer)
	n = write(wf._zio, p, nb)
	if n != nb
		error("short write")
	end
	
	a = pointer_to_array(p, nb)
	b = reinterpret(Uint8, reshape(a, length(a)))
	wf.crc32 = Zlib.crc32(b, wf.crc32)
	wf.uncompressedsize += n
	n
end

end # module
