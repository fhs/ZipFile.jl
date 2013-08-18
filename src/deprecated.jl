

function open(filename::String, new::Bool=false)
	if new
		return Writer(filename)
	end
	Dir(filename)
end

@deprecate open(filename::String)	Dir(filename)
@deprecate open(filename::String, new::Bool)	Writer(filename)
