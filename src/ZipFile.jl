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
	ios :: IOStream
	name :: String
	method :: Uint16
	dostime :: Uint16
	dosdate :: Uint16
	crc32 :: Uint32
	compressedsize :: Uint32
	uncompressedsize :: Uint32
	offset :: Uint32
end

type Dir
	ios :: IOStream
	files :: Vector{File}
	comment :: String
	
	Dir(ios::IOStream, files::Vector{File}, comment::String) =
		(x = new(ios, files, comment); finalizer(x, close); x)
end

type WritableFile
	f :: File
	closed :: Bool
	dirty :: Bool
	
	WritableFile(f::File, closed::Bool, dirty::Bool) =
		(x = new(f, closed, dirty); finalizer(x, close); x)
end
WritableFile(f::File) = WritableFile(f, false, false)

type WritableDir
	d :: Dir
	current :: Union(WritableFile, Nothing)
	closed :: Bool
	
	WritableDir(d::Dir, current::Union(WritableFile, Nothing), closed::Bool) =
		(x = new(d, current, closed); finalizer(x, close); x)
end
WritableDir(d::Dir) = WritableDir(d, nothing, false)

readle(ios::IOStream, ::Type{Uint32}) = htol(read(ios, Uint32))
readle(ios::IOStream, ::Type{Uint16}) = htol(read(ios, Uint16))

function writele(ios::IOStream, x::Vector{Uint8})
	n = write(ios, x)
	if n != length(x)
		error("short write")
	end
	n
end

writele(ios::IOStream, x::Uint16) = writele(ios, reinterpret(Uint8, [htol(x)]))
writele(ios::IOStream, x::Uint32) = writele(ios, reinterpret(Uint8, [htol(x)]))

# For MS-DOS time/date format, see:
# See http://msdn.microsoft.com/en-us/library/ms724247(v=VS.85).aspx
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

function find_enddiroffset(ios::IOStream)
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

function find_diroffset(ios::IOStream, enddiroffset::Integer)
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

function getfiles(ios::IOStream, diroffset::Integer, nfiles::Integer)
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

function open(filename::String, new::Bool=false)
	if new
		ios = Base.open(filename, "w")
		return WritableDir(Dir(ios, File[], ""))
	end
	ios = Base.open(filename)
	endoff = find_enddiroffset(ios)
	diroff, nfiles, comment = find_diroffset(ios, endoff)
	files = getfiles(ios, diroff, nfiles)
	Dir(ios, files, comment)
end

close(dir::Dir) = close(dir.ios)

function close(wd::WritableDir)
	if wd.closed
		return
	end
	wd.closed = true
	
	if !is(wd.current, nothing)
		close(wd.current)
		wd.current = nothing
	end

	cdpos = position(wd.d.ios)
	cdsize = 0
	
	# write central directory record
	for f in wd.d.files
		writele(f.ios, uint32(CentralDirSig))
		writele(f.ios, uint16(ZipVersion))
		writele(f.ios, uint16(ZipVersion))
		writele(f.ios, uint16(0))
		writele(f.ios, uint16(f.method))
		writele(f.ios, uint16(f.dostime))
		writele(f.ios, uint16(f.dosdate))
		writele(f.ios, uint32(f.crc32))
		writele(f.ios, uint32(f.compressedsize))
		writele(f.ios, uint32(f.uncompressedsize))
		b = convert(Vector{Uint8}, f.name)
		writele(f.ios, uint16(length(b)))
		writele(f.ios, uint16(0))
		writele(f.ios, uint16(0))
		writele(f.ios, uint16(0))
		writele(f.ios, uint16(0))
		writele(f.ios, uint32(0))
		writele(f.ios, uint32(f.offset))
		writele(f.ios, b)
		cdsize += 46+length(b)
	end
	
	# write end of central directory
	writele(wd.d.ios, uint32(EndCentralDirSig))
	writele(wd.d.ios, uint16(0))
	writele(wd.d.ios, uint16(0))
	writele(wd.d.ios, uint16(length(wd.d.files)))
	writele(wd.d.ios, uint16(length(wd.d.files)))
	writele(wd.d.ios, uint32(cdsize))
	writele(wd.d.ios, uint32(cdpos))
	writele(wd.d.ios, uint16(0))
	
	close(wd.d)
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

function addfile(wd::WritableDir, name::String; method::Integer=Store, mtime::Float64=-1.0)
	if !is(wd.current, nothing)
		close(wd.current)
		wd.current = nothing
	end
	
	if mtime < 0
		mtime = time()
	end
	dostime, dosdate = msdostime(mtime)
	f = File(wd.d.ios, name, uint16(method), dostime, dosdate,
		uint32(0), uint32(0), uint32(0), uint32(position(wd.d.ios)))
	
	# Write local file header. Missing entries will be filled in later.
	writele(f.ios, uint32(LocalFileHdrSig))
	writele(f.ios, uint16(ZipVersion))
	writele(f.ios, uint16(0))
	writele(f.ios, uint16(f.method))
	writele(f.ios, uint16(f.dostime))
	writele(f.ios, uint16(f.dosdate))
	writele(f.ios, uint32(f.crc32))	# filler
	writele(f.ios, uint32(f.compressedsize))	# filler
	writele(f.ios, uint32(f.uncompressedsize))	# filler
	b = convert(Vector{Uint8}, f.name)
	writele(f.ios, uint16(length(b)))
	writele(f.ios, uint16(0))
	writele(f.ios, b)

	wd.d.files = [wd.d.files, f]
	wd.current = WritableFile(f)
	wd.current
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
