module ZipFile

# ZIP file format is described in
# http://www.pkware.com/documents/casestudies/APPNOTE.TXT

import Base: readall, write, close, mtime
import Zlib

export readall, write, close, mtime

# TODO: ZIP64 support, data descriptor support
# TODO: support partial read of File

const LocalFileHdrSig   = 0x04034b50
const CentralDirSig     = 0x02014b50
const EndCentralDirSig  = 0x06054b50
const ZipVersion = 20
const Store = 0
const Deflate = 8

type File
	ios :: IO
	name :: String
	method :: Uint16
	dostime :: Uint16
	dosdate :: Uint16
	crc32 :: Uint32
	compressedsize :: Uint32
	uncompressedsize :: Uint32
	offset :: Uint32
end

type Reader
	ios :: IO
	files :: Vector{File}
	comment :: String
	
	Reader(ios::IO, files::Vector{File}, comment::String) =
		(x = new(ios, files, comment); finalizer(x, close); x)
end

function Reader(filename::String)
	ios = Base.open(filename)
	endoff = find_enddiroffset(ios)
	diroff, nfiles, comment = find_diroffset(ios, endoff)
	files = getfiles(ios, diroff, nfiles)
	Reader(ios, files, comment)
end

type WritableFile
	f :: File
	closed :: Bool
	dirty :: Bool
	
	WritableFile(f::File, closed::Bool, dirty::Bool) =
		(x = new(f, closed, dirty); finalizer(x, close); x)
end
WritableFile(f::File) = WritableFile(f, false, false)

type Writer
	ios :: IO
	files :: Vector{File}
	current :: Union(WritableFile, Nothing)
	closed :: Bool
	
	Writer(ios::IO, files::Vector{File},
		current::Union(WritableFile, Nothing), closed::Bool) =
		(x = new(ios, files, current, closed); finalizer(x, close); x)
end
Writer(ios::IO, files::Vector{File}) = Writer(ios, files, nothing, false)
Writer(filename::String) = Writer(Base.open(filename, "w"), File[])

include("deprecated.jl")

readle(ios::IO, ::Type{Uint32}) = htol(read(ios, Uint32))
readle(ios::IO, ::Type{Uint16}) = htol(read(ios, Uint16))

function writele(ios::IO, x::Vector{Uint8})
	n = write(ios, x)
	if n != length(x)
		error("short write")
	end
	n
end

writele(ios::IO, x::Uint16) = writele(ios, reinterpret(Uint8, [htol(x)]))
writele(ios::IO, x::Uint32) = writele(ios, reinterpret(Uint8, [htol(x)]))

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

function find_enddiroffset(ios::IO)
	seekend(ios)
	filesize = position(ios)
	offset = None

	# Look for end of central directory locator in the last 1KB.
	# Failing that, look for it in the last 65KB.
	for guess in [1024, 65*1024]
		if ~is(offset, None)
			break
		end
		k = min(filesize, guess)
		n = filesize-k
		seek(ios, n)
		b = read(ios, Uint8, k)
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

function find_diroffset(ios::IO, enddiroffset::Integer)
	seek(ios, enddiroffset)
	if readle(ios, Uint32) != EndCentralDirSig
		error("internal error")
	end
	skip(ios, 2+2+2)
	nfiles = read(ios, Uint16)
	skip(ios, 4)
	offset = readle(ios, Uint32)
	commentlen = readle(ios, Uint16)
	comment = utf8(read(ios, Uint8, commentlen))
	offset, nfiles, comment
end

function getfiles(ios::IO, diroffset::Integer, nfiles::Integer)
	seek(ios, diroffset)
	files = Array(File, nfiles)
	for i in 1:nfiles
		if readle(ios, Uint32) != CentralDirSig
			error("invalid file header")
		end
		skip(ios, 2+2)
		flag = readle(ios, Uint16)
		if (flag & (1<<0)) != 0
			error("encryption not supported")
		end
		if (flag & (1<<3)) != 0
			error("data descriptor not supported")
		end
		method = readle(ios, Uint16)
		dostime = readle(ios, Uint16)
		dosdate = readle(ios, Uint16)
		crc32 = readle(ios, Uint32)
		compsize = readle(ios, Uint32)
		uncompsize = readle(ios, Uint32)
		namelen = readle(ios, Uint16)
		extralen = readle(ios, Uint16)
		commentlen = readle(ios, Uint16)
		skip(ios, 2+2+4)
		offset = readle(ios, Uint32)
		name = utf8(read(ios, Uint8, namelen))
		skip(ios, extralen+commentlen)
		files[i] = File(ios, name, method, dostime, dosdate,
			crc32, compsize, uncompsize, offset)
	end
	files
end

close(dir::Reader) = close(dir.ios)

function close(w::Writer)
	if w.closed
		return
	end
	w.closed = true
	
	if !is(w.current, nothing)
		close(w.current)
		w.current = nothing
	end

	cdpos = position(w.ios)
	cdsize = 0
	
	# write central directory record
	for f in w.files
		writele(w.ios, uint32(CentralDirSig))
		writele(w.ios, uint16(ZipVersion))
		writele(w.ios, uint16(ZipVersion))
		writele(w.ios, uint16(0))
		writele(w.ios, uint16(f.method))
		writele(w.ios, uint16(f.dostime))
		writele(w.ios, uint16(f.dosdate))
		writele(w.ios, uint32(f.crc32))
		writele(w.ios, uint32(f.compressedsize))
		writele(w.ios, uint32(f.uncompressedsize))
		b = convert(Vector{Uint8}, f.name)
		writele(w.ios, uint16(length(b)))
		writele(w.ios, uint16(0))
		writele(w.ios, uint16(0))
		writele(w.ios, uint16(0))
		writele(w.ios, uint16(0))
		writele(w.ios, uint32(0))
		writele(w.ios, uint32(f.offset))
		writele(w.ios, b)
		cdsize += 46+length(b)
	end
	
	# write end of central directory
	writele(w.ios, uint32(EndCentralDirSig))
	writele(w.ios, uint16(0))
	writele(w.ios, uint16(0))
	writele(w.ios, uint16(length(w.files)))
	writele(w.ios, uint16(length(w.files)))
	writele(w.ios, uint32(cdsize))
	writele(w.ios, uint32(cdpos))
	writele(w.ios, uint16(0))
	
	close(w.ios)
end

function close(wf::WritableFile)
	if wf.closed
		return
	end
	wf.closed = true
	
	# fill in local file header fillers
	seek(wf.f.ios, wf.f.offset+14)	# seek to CRC-32
	writele(wf.f.ios, uint32(wf.f.crc32))
	writele(wf.f.ios, uint32(wf.f.compressedsize))
	writele(wf.f.ios, uint32(wf.f.uncompressedsize))
	seekend(wf.f.ios)
end

function readbytes(f::File)
	seek(f.ios, f.offset)
	if readle(f.ios, Uint32) != LocalFileHdrSig
		error("invalid file header")
	end
	skip(f.ios, 2+2+2+2+2+4+4+4)
	filelen = readle(f.ios, Uint16)
	extralen = readle(f.ios, Uint16)
	skip(f.ios, filelen+extralen)
	data = None
	if f.method == Store
		data = read(f.ios, Uint8, f.uncompressedsize)
	elseif f.method == Deflate
		data = Zlib.decompress(read(f.ios, Uint8, f.compressedsize), true)
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
	f = File(w.ios, name, uint16(method), dostime, dosdate,
		uint32(0), uint32(0), uint32(0), uint32(position(w.ios)))
	
	# Write local file header. Missing entries will be filled in later.
	writele(w.ios, uint32(LocalFileHdrSig))
	writele(w.ios, uint16(ZipVersion))
	writele(w.ios, uint16(0))
	writele(w.ios, uint16(f.method))
	writele(w.ios, uint16(f.dostime))
	writele(w.ios, uint16(f.dosdate))
	writele(w.ios, uint32(f.crc32))	# filler
	writele(w.ios, uint32(f.compressedsize))	# filler
	writele(w.ios, uint32(f.uncompressedsize))	# filler
	b = convert(Vector{Uint8}, f.name)
	writele(w.ios, uint16(length(b)))
	writele(w.ios, uint16(0))
	writele(w.ios, b)

	w.files = [w.files, f]
	w.current = WritableFile(f)
	w.current
end

function write(wf::WritableFile, data::Vector{Uint8})
	if wf.f.method == Deflate && wf.dirty
		error("multiple deflate writes not supported")
	end
	wf.dirty = true
	
	wf.f.uncompressedsize += length(data)
	wf.f.crc32 = Zlib.crc32(data, wf.f.crc32)
	if wf.f.method == Deflate
		data = Zlib.compress(data, false, true)
	end
	n = write(wf.f.ios, data)
	wf.f.compressedsize += n
	n
end

write(wf::WritableFile, data::String) = write(wf, convert(Vector{Uint8}, data))

end # module
