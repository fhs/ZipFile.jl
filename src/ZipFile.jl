module ZipFile

import Base: readall, close
import Zlib
using CRC32

export zipopen, close, readall

# TODO: ZIP64 support, data descriptor support
# TODO: support partial read of File

const LocalFileHdrSig   = 0x04034b50
const CentralDirSig     = 0x02014b50
const EndCentralDirSig  = 0x06054b50
const Store = 0
const Deflate = 8

type File
	ios :: IOStream
	name :: String
	compression :: Integer
	crc32 :: Integer
	compressedsize :: Integer
	uncompressedsize :: Integer
	offset :: Integer
end

type Dir
	ios :: IOStream
	files :: Vector{File}
	comment :: String
end

readle(ios, ::Type{Uint32}) = htol(read(ios, Uint32))
readle(ios, ::Type{Uint16}) = htol(read(ios, Uint16))

function find_enddiroffset(ios)
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

function find_diroffset(ios, enddiroffset)
	seek(ios, enddiroffset)
	if readle(ios, Uint32) != EndCentralDirSig
		error("internal error")
	end
	skip(ios, 2+2+2)
	nfiles = read(ios, Uint16)
	skip(ios, 4)
	offset = readle(ios, Uint32)
	commentlen = readle(ios, Uint16)
	comment = string(char(read(ios, Uint8, commentlen))...)
	offset, nfiles, comment
end

function getfiles(ios, diroffset, nfiles)
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
		compression = readle(ios, Uint16)
		skip(ios, 2+2)
		crc32 = readle(ios, Uint32)
		compsize = readle(ios, Uint32)
		uncompsize = readle(ios, Uint32)
		namelen = readle(ios, Uint16)
		extralen = readle(ios, Uint16)
		commentlen = readle(ios, Uint16)
		skip(ios, 2+2+4)
		offset = readle(ios, Uint32)
		name = string(char(read(ios, Uint8, namelen))...)
		skip(ios, extralen+commentlen)
		files[i] = File(ios, name, compression, crc32, compsize, uncompsize, offset)
	end
	files
end

function zipopen(filename)
	ios = open(filename)
	endoff = find_enddiroffset(ios)
	diroff, nfiles, comment = find_diroffset(ios, endoff)
	files = getfiles(ios, diroff, nfiles)
	Dir(ios, files, comment)
end

function close(dir::Dir)
	close(dir.ios)
end

function readall(f::File)
	seek(f.ios, f.offset)
	if readle(f.ios, Uint32) != LocalFileHdrSig
		error("invalid file header")
	end
	skip(f.ios, 2+2+2+2+2+4+4+4)
	filelen = readle(f.ios, Uint16)
	extralen = readle(f.ios, Uint16)
	skip(f.ios, filelen+extralen)
	data = None
	if f.compression == Store
		data = read(f.ios, Uint8, f.uncompressedsize)
	elseif f.compression == Deflate
		data = Zlib.decompress(read(f.ios, Uint8, f.compressedsize), true)
	else
		error("unknown compression method $(f.compression)")
	end
	if crc32(data) != f.crc32
		error("crc32 do not match")
	end
	data
end

end # module
