# Writer the content of a into w.
function write(w::WritableFile, a::Array{UInt8})
	write(w, pointer(a), length(a))
end

# Writer the content of a into w.
if isdefined(:CartesianRange)
	function write{T,N,A<:Array}(w::WritableFile, a::SubArray{T,N,A})
		# This function is copied from Julia base/io.jl
		if !isbits(T) || stride(a,1)!=1
			return invoke(write, (Any, AbstractArray), s, a)
		end
		colsz = size(a,1)*sizeof(T)
		if N<=1
			return write(w, pointer(a, 1), colsz)
		else
			# cartesianmap was deprecated by v0.4.0-RC1.
			for idx in CartesianRange(tuple(1, size(a)[2:end]...))
				write(w, pointer(a, idx.I), colsz)
			end
			return colsz*Base.trailingsize(a,2)
		end
	end
else
	function write{T,N,A<:Array}(w::WritableFile, a::SubArray{T,N,A})
		# This function is copied from Julia base/io.jl
		if !isbits(T) || stride(a,1)!=1
			return invoke(write, (Any, AbstractArray), s, a)
		end
		colsz = size(a,1)*sizeof(T)
		if N<=1
			return write(w, pointer(a, 1), colsz)
		else
			cartesianmap((idxs...)->write(w, pointer(a, idxs), colsz),
				tuple(1, size(a)[2:end]...))
			return colsz*Base.trailingsize(a,2)
		end
	end
end

# Writer the byte b in w.
function write(w::WritableFile, b::UInt8)
	write(w, UInt8[b])
end

# Read and return a byte from f. Throws EOFError if there is no more byte to read.
function read(f::ReadableFile, ::Type{UInt8})
	# This function needs to be fast because readbytes, readall, etc.
	# uses it. Avoid function calls when possible.
	b = Array(UInt8, 1)
	read(f, b)
	b[1]
end
