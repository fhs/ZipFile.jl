

function open(filename::String, new::Bool=false)
	if new
		return WritableDir(filename)
	end
	Dir(filename)
end

@deprecate open(filename::String)	Dir(filename)
@deprecate open(filename::String, new::Bool)	WritableDir(filename)
