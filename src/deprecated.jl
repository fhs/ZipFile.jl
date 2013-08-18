
@deprecate open(filename::String)	Reader(filename)
@deprecate open(filename::String, new::Bool)	(new? Writer(filename) : Reader(filename))
