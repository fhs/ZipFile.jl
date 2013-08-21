
function open(filename::String, new::Bool=false)
	Base.warn_once("ZipFile.open is deprecated, use ZipFile.Reader or ZipFile.Writer.")
	new ? Writer(filename) : Reader(filename)
end
