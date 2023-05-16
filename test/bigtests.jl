# These tests require over 8 GB of memory and a 64 bit Int

using ZipFile
using Test

@testset "big array with Zlib" begin
    big_array = collect(1:2^29+2^25)
    
    io = IOBuffer()
    w = ZipFile.Zlib.Writer(io, 1, true)
    write(w, big_array)
    close(w)
    w = nothing
    @info "done writing big_array"
    seekstart(io)
    r = ZipFile.Zlib.Reader(io, true)
    buffer = zeros(Int, 2^22)
    for bi in 1:(length(big_array)>>22)
        read!(r, buffer)
        @test ((bi-1)<<22+1):(bi<<22) == buffer
    end
    close(r)
    r = nothing
    close(io)
    io = nothing
    @info "done reading big_array"

    # Check that crc32 works
    crc32_big::UInt32 = ZipFile.Zlib.crc32(
        reinterpret(UInt8, big_array)
    )
    crc32_parts::UInt32 = 0
    for bi in 1:(length(big_array)>>22)
        crc32_parts = ZipFile.Zlib.crc32(
            reinterpret(UInt8, view(big_array,((bi-1)<<22+1):(bi<<22))),
            crc32_parts
        )
    end
    @test crc32_parts == crc32_big

    
    big_array = nothing
end