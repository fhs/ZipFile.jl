# Writer the byte b in w.
function write(w::WritableFile, b::UInt8)
    write(w, Ref(b))
end