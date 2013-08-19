module ZipFile

# ZIP file format is described in
# http://www.pkware.com/documents/casestudies/APPNOTE.TXT

import Base: readall, write, close, mtime, position
import Zlib

export readall, write, close, mtime, position

# TODO: ZIP64 support, data descriptor support
# TODO: support partial read of File

const LocalFileHdrSig   = 0x04034b50
const CentralDirSig     = 0x02014b50
const EndCentralDirSig  = 0x06054b50
const ZipVersion = 20
const Store = 0
const Deflate = 8

type File
	io :: IO
	name :: String
	method :: Uint16
	dostime :: Uint16
	dosdate :: Uint16
	crc32 :: Uint32
	compressedsize :: Uint32
	uncompressedsize :: Uint32
	offset :: Uint32
	
	function File(io::IO, name::String, method::Uint16, dostime::Uint16,
			dosdate::Uint16, crc32::Uint32, compressedsize::Uint32,
			uncompressedsize::Uint32, offset::Uint32)
		if method != Store && method != Deflate
			error("unknown compression method $method")
		end
		new(io, name, method, dostime, dosdate, crc32,
			compressedsize, uncompressedsize, offset)
	end
		
end

type Reader
	io :: IO
	files :: Vector{File}
	comment :: String
	
	Reader(io::IO, files::Vector{File}, comment::String) =
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
	io :: IO		# wrapper IO for Deflate, etc.
	f :: File
	closed :: Bool
	startpos :: Int64	# position where data begins
	
	WritableFile(io::IO, f::File, closed::Bool, startpos::Int64) =
		(x = new(io, f, closed, startpos); finalizer(x, close); x)
end
WritableFile(io::IO, f::File) = WritableFile(io, f, false, position(f.io))

type Writer
	io :: IO
	files :: Vector{File}
	current :: Union(WritableFile, Nothing)
	closed :: Bool
	
	Writer(io::IO, files::Vector{File},
		current::Union(WritableFile, Nothing), closed::Bool) =
		(x = new(io, files, current, closed); finalizer(x, close); x)
end
Writer(io::IO, files::Vector{File}) = Writer(io, files, nothing, false)
Writer(filename::String) = Writer(Base.open(filename, "w"), File[])

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
function mtime(f::File)
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
	files = Array(File, nfiles)
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
		files[i] = File(io, name, method, dostime, dosdate,
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
	
	if wf.f.method == Deflate
		close(wf.io)
	end
	wf.f.compressedsize = position(wf)
	
	# fill in local file header fillers
	seek(wf.f.io, wf.f.offset+14)	# seek to CRC-32
	writele(wf.f.io, uint32(wf.f.crc32))
	writele(wf.f.io, uint32(wf.f.compressedsize))
	writele(wf.f.io, uint32(wf.f.uncompressedsize))
	seekend(wf.f.io)
end

function readbytes(f::File)
	seek(f.io, f.offset)
	if readle(f.io, Uint32) != LocalFileHdrSig
		error("invalid file header")
	end
	skip(f.io, 2+2+2+2+2+4+4+4)
	filelen = readle(f.io, Uint16)
	extralen = readle(f.io, Uint16)
	skip(f.io, filelen+extralen)
	data = None
	if f.method == Store
		data = read(f.io, Uint8, f.uncompressedsize)
	elseif f.method == Deflate
		data = Zlib.decompress(read(f.io, Uint8, f.compressedsize), true)
	else
		error("unknown compression method $(f.method)")
	end
	if Zlib.crc32(data) != f.crc32
		error("crc32 do not match")
	end
	data
end

function readall(f::File)
	b = readbytes(f)
	return is_valid_ascii(b) ? ASCIIString(b) : UTF8String(b)
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
	f = File(w.io, name, uint16(method), dostime, dosdate,
		uint32(0), uint32(0), uint32(0), uint32(position(w.io)))
	
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

	w.files = [w.files, f]
	if f.method == Store
		w.current = WritableFile(f.io, f)
	elseif f.method == Deflate
		w.current = WritableFile(Zlib.Writer(f.io, false, true), f)
	end
	w.current
end

function position(wf::WritableFile)
	position(wf.f.io) - wf.startpos
end

function write(wf::WritableFile, p::Ptr, nb::Integer)
	n = write(wf.io, p, nb)
	if n != nb
		error("short write")
	end
	wf.f.crc32 = Zlib.crc32(pointer_to_array(p, nb), wf.f.crc32)
	wf.f.uncompressedsize += n
	n
end

end # module
