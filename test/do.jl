mutable struct DoBlockFlushIO <: IO
    buffer::IOBuffer
    failure::Exception
end
Base.unsafe_write(io::DoBlockFlushIO, pointer::Ptr{UInt8}, count::UInt) = unsafe_write(io.buffer, pointer, count)
Base.position(io::DoBlockFlushIO) = position(io.buffer)
Base.seek(io::DoBlockFlushIO, position::Integer) = (seek(io.buffer, position); io)
Base.flush(io::DoBlockFlushIO) = throw(io.failure)
Base.close(io::DoBlockFlushIO) = close(io.buffer)
Base.isopen(io::DoBlockFlushIO) = isopen(io.buffer)

@testset "do-block empty archive" begin
    io = IOBuffer()
    @test ZipFile.Writer(_ -> :empty, io) === :empty
    @test isopen(io)
    seekstart(io)
    @test ZipFile.Reader(archive -> isempty(archive.files), io)
    @test isopen(io)
    close(io)
end


@testset "do-block archive and entry ownership" begin
    mktempdir() do directory
        path = joinpath(directory, "callback.zip")
        marker = Ref(:archive_result)
        writer = Ref{ZipFile.Writer}()
        entries = ZipFile.WritableFile[]
        stamp = 1600000000.0
        result = ZipFile.Writer(SubString(path)) do archive
            writer[] = archive
            for (name, method, text) in (("stored.txt", ZipFile.Store, "stored\n"),
                                          ("nested/deflated.txt", ZipFile.Deflate, "deflated\n"))
                entry_result = ZipFile.addfile(archive, SubString(name); method=method, mtime=stamp) do entry
                    push!(entries, entry)
                    @test !entry._closed
                    write(entry, text)
                    marker
                end
                @test entry_result === marker
                @test entries[end]._closed
                @test isopen(archive._io)
            end
            marker
        end
        @test result === marker
        @test writer[]._closed
        @test !isopen(writer[]._io)
        reader = Ref{ZipFile.Reader}()
        result = ZipFile.Reader(SubString(path)) do archive
            reader[] = archive
            @test [entry.name for entry in archive.files] == ["stored.txt", "nested/deflated.txt"]
            @test [entry.method for entry in archive.files] == [ZipFile.Store, ZipFile.Deflate]
            @test [read(entry, String) for entry in archive.files] == ["stored\n", "deflated\n"]
            @test all(entry -> abs(mtime(entry) - stamp) < 2, archive.files)
            marker
        end
        @test result === marker
        @test !isopen(reader[]._io)
        rm(path) # No GC/finalizer is needed to release the owned file.
    end
end

@testset "do-block close errors retain finally semantics" begin
    for fail_callback in (false, true)
        closing = ErrorException("close sentinel")
        body = ErrorException("body sentinel")
        io = DoBlockFlushIO(IOBuffer(), closing)
        called = Ref(false)
        caught = try
            ZipFile.Writer(io) do archive
                called[] = true
                fail_callback && throw(body)
                :callback_result
            end
        catch error
            error
        end
        # Match the reporter's try/finally pattern and ordinary Julia open:
        # a close error is not swallowed, including after a callback error.
        @test called[]
        @test caught === closing
        @test isopen(io)
        close(io)
    end
end

@testset "do-block callback exceptions finalize archives" begin
    mktempdir() do directory
        for method in (ZipFile.Store, ZipFile.Deflate)
            path = joinpath(directory, string(method) * ".zip")
            original = ErrorException("callback sentinel")
            writer = Ref{ZipFile.Writer}()
            entry = Ref{ZipFile.WritableFile}()
            caught = try
                ZipFile.Writer(path) do archive
                    writer[] = archive
                    ZipFile.addfile(archive, "partial.txt"; method=method) do file
                        entry[] = file
                        write(file, "written before exception")
                        throw(original)
                    end
                end
                nothing
            catch error
                error
            end
            @test caught === original
            @test entry[]._closed
            @test writer[]._closed
            @test !isopen(writer[]._io)
            reader = Ref{ZipFile.Reader}()
            caught = try
                ZipFile.Reader(path) do archive
                    reader[] = archive
                    @test read(archive.files[1], String) == "written before exception"
                    throw(original)
                end
                nothing
            catch error
                error
            end
            @test caught === original
            @test !isopen(reader[]._io)
        end
    end
end

@testset "do-block external IO and one-open-entry rule" begin
    for method in (ZipFile.Store, ZipFile.Deflate), fail in (false, true)
        io = IOBuffer()
        original = ErrorException("external IO callback sentinel")
        writer = Ref{ZipFile.Writer}()
        caught = try
            ZipFile.Writer(io) do archive
                writer[] = archive
                ZipFile.addfile(archive, "first.txt"; method=method) do first
                    write(first, "first")
                    # A nested member still closes the previous member.
                    ZipFile.addfile(archive, "second.txt"; method=method) do second
                        @test first._closed
                        write(second, "second")
                    end
                    @test isopen(io)
                end
                fail && throw(original)
                :writer_result
            end
        catch error
            error
        end
        @test caught === (fail ? original : :writer_result)
        @test writer[]._closed
        @test isopen(io)
        seekstart(io)
        reader = Ref{ZipFile.Reader}()
        caught = try
            ZipFile.Reader(io) do archive
                reader[] = archive
                @test [read(entry, String) for entry in archive.files] == ["first", "second"]
                fail && throw(original)
                :reader_result
            end
        catch error
            error
        end
        @test caught === (fail ? original : :reader_result)
        @test isopen(io)
        close(io)
    end
end

@testset "entry callback errors leave the archive usable" begin
    io = IOBuffer()
    original = ErrorException("entry callback sentinel")
    ZipFile.Writer(io) do archive
        entry = Ref{ZipFile.WritableFile}()
        caught = try
            ZipFile.addfile(archive, "first.txt"; method=ZipFile.Deflate) do file
                entry[] = file
                write(file, "first")
                throw(original)
            end
            nothing
        catch error
            error
        end
        @test caught === original
        @test entry[]._closed
        @test isopen(io)
        ZipFile.addfile(archive, "second.txt") do file
            write(file, "second")
        end
    end
    seekstart(io)
    ZipFile.Reader(io) do archive
        @test [read(entry, String) for entry in archive.files] == ["first", "second"]
    end
    @test isopen(io)
    close(io)
end
