using Revise, CodeTracking, JuliaInterpreter
using Test

@test isempty(detect_ambiguities(Revise, Base, Core))

using Pkg, Unicode, Distributed, InteractiveUtils, REPL
import LibGit2
using OrderedCollections: OrderedSet
using Test: collect_test_logs
using Base.CoreLogging: Debug,Info

include("common.jl")

to_remove = String[]

throwing_function(bt) = bt[2]

function rm_precompile(pkgname::AbstractString)
    filepath = Base.cache_file_entry(Base.PkgId(pkgname))
    for depot in DEPOT_PATH
        fullpath = joinpath(depot, filepath)
        isfile(fullpath) && rm(fullpath)
    end
end

# A junk module that we can evaluate into
module ReviseTestPrivate
struct Inner
    x::Float64
end

macro changeto1(args...)
    return 1
end

macro donothing(ex)
    esc(ex)
end

macro addint(ex)
    :($(esc(ex))::$(esc(Int)))
end

# The following two submodules are for testing #199
module A
f(x::Int) = 1
end

module B
f(x::Int) = 1
module Core end
end

end

function private_module()
    modname = gensym()
    Core.eval(ReviseTestPrivate, :(module $modname end))
end

sig_type_exprs(ex) = Revise.sig_type_exprs(Main, ex)   # just for testing purposes

const pair_op_string = string(Dict(1=>2))[7:end-2]     # accomodate changes in Dict printing w/ Julia version

@testset "Revise" begin

    function collectexprs(rex::Revise.RelocatableExpr)
        items = []
        for item in Revise.LineSkippingIterator(rex.ex.args)
            push!(items, isa(item, Expr) ? Revise.RelocatableExpr(item) : item)
        end
        items
    end

    function get_docstring(ds)
        docstr = ds.content[1]
        while !isa(docstr, AbstractString)
            docstr = docstr.content[1]
        end
        return docstr
    end

    @testset "LineSkipping" begin
        rex = Revise.RelocatableExpr(quote
                                    f(x) = x^2
                                    g(x) = sin(x)
                                    end)
        @test length(Expr(rex).args) == 4  # including the line number expressions
        exs = collectexprs(rex)
        @test length(exs) == 2
        @test isequal(exs[1], Revise.RelocatableExpr(:(f(x) = x^2)))
        @test !isequal(exs[2], Revise.RelocatableExpr(:(f(x) = x^2)))
        @test isequal(exs[2], Revise.RelocatableExpr(:(g(x) = sin(x))))
        @test !isequal(exs[1], Revise.RelocatableExpr(:(g(x) = sin(x))))
        @test string(rex) == """
quote
    f(x) = begin
            x ^ 2
        end
    g(x) = begin
            sin(x)
        end
end"""
    end

    @testset "Parse errors" begin
        md = Revise.ModuleExprsSigs(Main)
        @test_throws LoadError Revise.parse_source!(md, """
begin # this block should parse correctly, cf. issue #109

end
f(x) = 1
g(x) = 2
h{x) = 3  # error
k(x) = 4
""", "test", Main)
    end

    @testset "Signature extraction" begin
        jidir = dirname(dirname(pathof(JuliaInterpreter)))
        scriptfile = joinpath(jidir, "test", "toplevel_script.jl")
        modex = :(module Toplevel include($scriptfile) end)
        mod = eval(modex)
        mexs = Revise.parse_source(scriptfile, mod)
        Revise.instantiate_sigs!(mexs)
        nms = names(mod; all=true)
        modeval, modinclude = getfield(mod, :eval), getfield(mod, :include)
        failed = []
        n = 0
        for fsym in nms
            f = getfield(mod, fsym)
            isa(f, Base.Callable) || continue
            (f === modeval || f === modinclude) && continue
            for m in methods(f)
                # MyInt8 brings in lots of number & type machinery, which leads
                # to wandering through Base files. At this point we just want
                # to test whether we have the basics down, so for now avoid
                # looking in any file other than the script
                string(m.file) == scriptfile || continue
                isa(definition(m), Expr) || push!(failed, m.sig)
                n += 1
            end
        end
        @test isempty(failed)
        @test n > length(nms)/2
    end

    @testset "Comparison and line numbering" begin
        # We'll also use these tests to try out the logging system
        rlogger = Revise.debug_logger()

        fl1 = joinpath(@__DIR__, "revisetest.jl")
        fl2 = joinpath(@__DIR__, "revisetest_revised.jl")
        fl3 = joinpath(@__DIR__, "revisetest_errors.jl")

        # Copy the files to a temporary file. This is to ensure that file name doesn't change
        # in docstring macros and backtraces.
        tmpfile = joinpath(tempdir(), randstring(10))*".jl"
        push!(to_remove, tmpfile)

        cp(fl1, tmpfile)
        include(tmpfile)  # So the modules are defined
        # test the "mistakes"
        @test ReviseTest.cube(2) == 16
        @test ReviseTest.Internal.mult3(2) == 8
        @test ReviseTest.Internal.mult4(2) == -2
        # One method will be deleted, for log testing we need to grab it while we still have it
        delmeth = first(methods(ReviseTest.Internal.mult4))
        mmult3 = @which ReviseTest.Internal.mult3(2)

        mexsold = Revise.parse_source(tmpfile, Main)
        Revise.instantiate_sigs!(mexsold)
        mcube = @which ReviseTest.cube(2)

        cp(fl2, tmpfile; force=true)
        mexsnew = Revise.parse_source(tmpfile, Main)
        mexsnew = Revise.eval_revised(mexsnew, mexsold)
        @test ReviseTest.cube(2) == 8
        @test ReviseTest.Internal.mult3(2) == 6

        @test length(mexsnew) == 3
        @test haskey(mexsnew, ReviseTest) && haskey(mexsnew, ReviseTest.Internal)

        dvs = collect(mexsnew[ReviseTest])
        @test length(dvs) == 3
        (def, val) = dvs[1]
        @test isequal(def, Revise.RelocatableExpr(:(square(x) = x^2)))
        @test val == [Tuple{typeof(ReviseTest.square),Any}]
        @test Revise.firstline(def).line == 5
        m = @which ReviseTest.square(1)
        @test m.line == 5
        @test whereis(m) == (tmpfile, 5)
        @test Revise.RelocatableExpr(definition(m)) == def
        (def, val) = dvs[2]
        @test isequal(def, Revise.RelocatableExpr(:(cube(x) = x^3)))
        @test val == [Tuple{typeof(ReviseTest.cube),Any}]
        m = @which ReviseTest.cube(1)
        @test m.line == 7
        @test whereis(m) == (tmpfile, 7)
        @test Revise.RelocatableExpr(definition(m)) == def
        (def, val) = dvs[3]
        @test isequal(def, Revise.RelocatableExpr(:(fourth(x) = x^4)))
        @test val == [Tuple{typeof(ReviseTest.fourth),Any}]
        m = @which ReviseTest.fourth(1)
        @test m.line == 9
        @test whereis(m) == (tmpfile, 9)
        @test Revise.RelocatableExpr(definition(m)) == def

        dvs = collect(mexsnew[ReviseTest.Internal])
        @test length(dvs) == 5
        (def, val) = dvs[1]
        @test isequal(def,  Revise.RelocatableExpr(:(mult2(x) = 2*x)))
        @test val == [Tuple{typeof(ReviseTest.Internal.mult2),Any}]
        @test Revise.firstline(def).line == 13
        m = @which ReviseTest.Internal.mult2(1)
        @test m.line == 11
        @test whereis(m) == (tmpfile, 13)
        @test Revise.RelocatableExpr(definition(m)) == def
        (def, val) = dvs[2]
        @test isequal(def, Revise.RelocatableExpr(:(mult3(x) = 3*x)))
        @test val == [Tuple{typeof(ReviseTest.Internal.mult3),Any}]
        m = @which ReviseTest.Internal.mult3(1)
        @test m.line == 14
        @test whereis(m) == (tmpfile, 14)
        @test Revise.RelocatableExpr(definition(m)) == def

        @test_throws MethodError ReviseTest.Internal.mult4(2)

        function cmpdiff(record, msg; kwargs...)
            record.message == msg
            for (kw, val) in kwargs
                logval = record.kwargs[kw]
                for (v, lv) in zip(val, logval)
                    isa(v, Expr) && (v = Revise.RelocatableExpr(v))
                    isa(lv, Expr) && (lv = Revise.RelocatableExpr(lv))
                    @test lv == v
                end
            end
            return nothing
        end
        logs = filter(r->r.level==Debug && r.group=="Action", rlogger.logs)
        @test length(logs) == 9
        cmpdiff(logs[1], "DeleteMethod"; deltainfo=(Tuple{typeof(ReviseTest.cube),Any}, MethodSummary(mcube)))
        cmpdiff(logs[2], "DeleteMethod"; deltainfo=(Tuple{typeof(ReviseTest.Internal.mult3),Any}, MethodSummary(mmult3)))
        cmpdiff(logs[3], "DeleteMethod"; deltainfo=(Tuple{typeof(ReviseTest.Internal.mult4),Any}, MethodSummary(delmeth)))
        cmpdiff(logs[4], "Eval"; deltainfo=(ReviseTest, :(cube(x) = x^3)))
        cmpdiff(logs[5], "Eval"; deltainfo=(ReviseTest, :(fourth(x) = x^4)))
        stmpfile = Symbol(tmpfile)
        cmpdiff(logs[6], "LineOffset"; deltainfo=(Any[Tuple{typeof(ReviseTest.Internal.mult2),Any}], LineNumberNode(11,stmpfile)=>LineNumberNode(13,stmpfile)))
        cmpdiff(logs[7], "Eval"; deltainfo=(ReviseTest.Internal, :(mult3(x) = 3*x)))
        cmpdiff(logs[8], "LineOffset"; deltainfo=(Any[Tuple{typeof(ReviseTest.Internal.unchanged),Any}], LineNumberNode(18,stmpfile)=>LineNumberNode(19,stmpfile)))
        cmpdiff(logs[9], "LineOffset"; deltainfo=(Any[Tuple{typeof(ReviseTest.Internal.unchanged2),Any}], LineNumberNode(20,stmpfile)=>LineNumberNode(21,stmpfile)))
        @test length(Revise.actions(rlogger)) == 6  # by default LineOffset is skipped
        @test length(Revise.actions(rlogger; line=true)) == 9
        @test_broken length(Revise.diffs(rlogger)) == 2
        empty!(rlogger.logs)

        # Backtraces
        cp(fl3, tmpfile; force=true)
        mexsold = mexsnew
        mexsnew = Revise.parse_source(tmpfile, Main)
        mexsnew = Revise.eval_revised(mexsnew, mexsold)
        try
            ReviseTest.cube(2)
            @test false
        catch err
            @test isa(err, ErrorException) && err.msg == "cube"
            bt = throwing_function(stacktrace(catch_backtrace()))
            @test bt.func == :cube && bt.file == Symbol(tmpfile) && bt.line == 7
        end
        try
            ReviseTest.Internal.mult2(2)
            @test false
        catch err
            @test isa(err, ErrorException) && err.msg == "mult2"
            bt = throwing_function(stacktrace(catch_backtrace()))
            @test bt.func == :mult2 && bt.file == Symbol(tmpfile) && bt.line == 13
        end

        logs = filter(r->r.level==Debug && r.group=="Action", rlogger.logs)
        @test length(logs) == 4
        cmpdiff(logs[3], "Eval"; deltainfo=(ReviseTest, :(cube(x) = error("cube"))))
        cmpdiff(logs[4], "Eval"; deltainfo=(ReviseTest.Internal, :(mult2(x) = error("mult2"))))

        # Turn off future logging
        Revise.debug_logger(; min_level=Info)

        # Gensymmed symbols
        rex1 = Revise.RelocatableExpr(macroexpand(Main, :(t = @elapsed(foo(x)))))
        rex2 = Revise.RelocatableExpr(macroexpand(Main, :(t = @elapsed(foo(x)))))
        @test isequal(rex1, rex2)
        @test hash(rex1) == hash(rex2)
        rex3 = Revise.RelocatableExpr(macroexpand(Main, :(t = @elapsed(bar(x)))))
        @test !isequal(rex1, rex3)
        @test hash(rex1) != hash(rex3)
        sym1, sym2 = gensym(:hello), gensym(:hello)
        rex1 = Revise.RelocatableExpr(:(x = $sym1))
        rex2 = Revise.RelocatableExpr(:(x = $sym2))
        @test isequal(rex1, rex2)
        @test hash(rex1) == hash(rex2)
        sym3 = gensym(:world)
        rex3 = Revise.RelocatableExpr(:(x = $sym3))
        @test isequal(rex1, rex3)
        @test hash(rex1) == hash(rex3)
    end

    @testset "Display" begin
        io = IOBuffer()
        show(io, Revise.RelocatableExpr(:(@inbounds x[2])))
        str = String(take!(io))
        @test str == ":(@inbounds x[2])"
        mod = private_module()
        file = joinpath(@__DIR__, "revisetest.jl")
        Base.include(mod, file)
        mexs = Revise.parse_source(file, mod)
        Revise.instantiate_sigs!(mexs)
        @test string(mexs) == "OrderedCollections.OrderedDict($mod$(pair_op_string)ExprsSigs(<1 expressions>, <0 signatures>),$mod.ReviseTest$(pair_op_string)ExprsSigs(<2 expressions>, <2 signatures>),$mod.ReviseTest.Internal$(pair_op_string)ExprsSigs(<6 expressions>, <5 signatures>))"
        exs = mexs[getfield(mod, :ReviseTest)]
        io = IOBuffer()
        print(IOContext(io, :compact=>true), exs)
        @test String(take!(io)) == "ExprsSigs(<2 expressions>, <2 signatures>)"
        print(IOContext(io, :compact=>false), exs)
        str = String(take!(io))
        @test str == "ExprsSigs with the following expressions: \n  :(square(x) = begin\n          x ^ 2\n      end)\n  :(cube(x) = begin\n          x ^ 4\n      end)"
    end

    @testset "File paths" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        for (pcflag, fbase) in ((true, "pc"), (false, "npc"),)  # precompiled & not
            modname = uppercase(fbase)
            pcexpr = pcflag ? "" : :(__precompile__(false))
            # Create a package with the following structure:
            #   src/PkgName.jl   # PC.jl = precompiled, NPC.jl = nonprecompiled
            #   src/file2.jl
            #   src/subdir/file3.jl
            #   src/subdir/file4.jl
            # exploring different ways of expressing the `include` statement
            dn = joinpath(testdir, modname, "src")
            mkpath(dn)
            open(joinpath(dn, modname*".jl"), "w") do io
                println(io, """
$pcexpr
module $modname

export $(fbase)1, $(fbase)2, $(fbase)3, $(fbase)4, $(fbase)5, using_macro_$(fbase)

$(fbase)1() = 1

include("file2.jl")
include("subdir/file3.jl")
include(joinpath(@__DIR__, "subdir", "file4.jl"))
otherfile = "file5.jl"
include(otherfile)

# Update order check: modifying `some_macro_` to return -6 doesn't change the
# return value of `using_macro_` (issue #20) unless `using_macro_` is also updated,
# *in this order*:
#   1. update the `@some_macro_` definition
#   2. update the `using_macro_` definition
macro some_macro_$(fbase)()
    return 6
end
using_macro_$(fbase)() = @some_macro_$(fbase)()

end
""")
            end
            open(joinpath(dn, "file2.jl"), "w") do io
                println(io, "$(fbase)2() = 2")
            end
            mkdir(joinpath(dn, "subdir"))
            open(joinpath(dn, "subdir", "file3.jl"), "w") do io
                println(io, "$(fbase)3() = 3")
            end
            open(joinpath(dn, "subdir", "file4.jl"), "w") do io
                println(io, "$(fbase)4() = 4")
            end
            open(joinpath(dn, "file5.jl"), "w") do io
                println(io, "$(fbase)5() = 5")
            end
            sleep(2.1)   # so the defining files are old enough not to trigger mtime criterion
            @eval using $(Symbol(modname))
            fn1, fn2 = Symbol("$(fbase)1"), Symbol("$(fbase)2")
            fn3, fn4 = Symbol("$(fbase)3"), Symbol("$(fbase)4")
            fn5 = Symbol("$(fbase)5")
            fn6 = Symbol("using_macro_$(fbase)")
            @eval @test $(fn1)() == 1
            @eval @test $(fn2)() == 2
            @eval @test $(fn3)() == 3
            @eval @test $(fn4)() == 4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == 6
            m = @eval first(methods($fn1))
            # yield()
            rex = Revise.RelocatableExpr(definition(m))
            @test rex == convert(Revise.RelocatableExpr, :( $fn1() = 1 ))
            # Check that definition returns copies
            rex2 = deepcopy(rex)
            rex.ex.args[end].args[end] = 2
            @test Revise.RelocatableExpr(definition(m)) == rex2
            @test Revise.RelocatableExpr(definition(m)) != rex
            # CodeTracking methods
            m3 = first(methods(eval(fn3)))
            m3file = joinpath(dn, "subdir", "file3.jl")
            @test whereis(m3) == (m3file, 1)
            @test signatures_at(m3file, 1) == [m3.sig]
            @test signatures_at(eval(Symbol(modname)), joinpath("src", "subdir", "file3.jl"), 1) == [m3.sig]

            sleep(0.1)  # to ensure that the file watching has kicked in
            # Change the definition of function 1 (easiest to just rewrite the whole file)
            open(joinpath(dn, modname*".jl"), "w") do io
                println(io, """
$pcexpr
module $modname
export $(fbase)1, $(fbase)2, $(fbase)3, $(fbase)4, $(fbase)5, using_macro_$(fbase)
$(fbase)1() = -1
include("file2.jl")
include("subdir/file3.jl")
include(joinpath(@__DIR__, "subdir", "file4.jl"))
otherfile = "file5.jl"
include(otherfile)

macro some_macro_$(fbase)()
    return -6
end
using_macro_$(fbase)() = @some_macro_$(fbase)()

end
""")  # just for fun we skipped the whitespace
            end
            sleep(0.1)
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == 2
            @eval @test $(fn3)() == 3
            @eval @test $(fn4)() == 4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == 6      # because it hasn't been re-macroexpanded
            @test revise(eval(Symbol(modname)))
            @eval @test $(fn6)() == -6
            # Redefine function 2
            open(joinpath(dn, "file2.jl"), "w") do io
                println(io, "$(fbase)2() = -2")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == 3
            @eval @test $(fn4)() == 4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == -6
            open(joinpath(dn, "subdir", "file3.jl"), "w") do io
                println(io, "$(fbase)3() = -3")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == -3
            @eval @test $(fn4)() == 4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == -6
            open(joinpath(dn, "subdir", "file4.jl"), "w") do io
                println(io, "$(fbase)4() = -4")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == -3
            @eval @test $(fn4)() == -4
            @eval @test $(fn5)() == 5
            @eval @test $(fn6)() == -6
            open(joinpath(dn, "file5.jl"), "w") do io
                println(io, "$(fbase)5() = -5")
            end
            yry()
            @eval @test $(fn1)() == -1
            @eval @test $(fn2)() == -2
            @eval @test $(fn3)() == -3
            @eval @test $(fn4)() == -4
            @eval @test $(fn5)() == -5
            @eval @test $(fn6)() == -6
            # Check that the list of files is complete
            pkgdata = Revise.pkgdatas[Base.PkgId(modname)]
            for file = [joinpath("src", modname*".jl"), joinpath("src", "file2.jl"),
                        joinpath("src", "subdir", "file3.jl"),
                        joinpath("src", "subdir", "file4.jl"),
                        joinpath("src", "file5.jl")]
                @test Revise.hasfile(pkgdata, file)
            end
        end
        # Remove the precompiled file
        rm_precompile("PC")

        # Submodules (issue #142)
        srcdir = joinpath(testdir, "Mysupermodule", "src")
        subdir = joinpath(srcdir, "Mymodule")
        mkpath(subdir)
        open(joinpath(srcdir, "Mysupermodule.jl"), "w") do io
            print(io, """
                module Mysupermodule
                include("Mymodule/Mymodule.jl")
                end
                """)
        end
        open(joinpath(subdir, "Mymodule.jl"), "w") do io
            print(io, """
                module Mymodule
                include("filesub.jl")
                end
                """)
        end
        open(joinpath(subdir, "filesub.jl"), "w") do io
            print(io, """
                func() = 1
                """)
        end
        sleep(2.1)
        @eval using Mysupermodule
        @test Mysupermodule.Mymodule.func() == 1
        sleep(1.1)
        yry()
        open(joinpath(subdir, "filesub.jl"), "w") do io
            print(io, """
                func() = 2
                """)
        end
        yry()
        @test Mysupermodule.Mymodule.func() == 2
        rm_precompile("Mymodule")
        rm_precompile("Mysupermodule")

        # Test files paths that can't be statically parsed
        dn = joinpath(testdir, "LoopInclude", "src")
        mkpath(dn)
        open(joinpath(dn, "LoopInclude.jl"), "w") do io
            println(io, """
module LoopInclude

export li_f, li_g

for fn in ("file1.jl", "file2.jl")
    include(fn)
end

end
""")
        end
        open(joinpath(dn, "file1.jl"), "w") do io
            println(io, "li_f() = 1")
        end
        open(joinpath(dn, "file2.jl"), "w") do io
            println(io, "li_g() = 2")
        end
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using LoopInclude
        sleep(0.1) # to ensure file-watching is set up
        @test li_f() == 1
        @test li_g() == 2
        sleep(1.1)  # ensure watching is set up
        yry()
        open(joinpath(dn, "file1.jl"), "w") do io
            println(io, "li_f() = -1")
        end
        yry()
        @test li_f() == -1
        rm_precompile("LoopInclude")
        # Multiple packages in the same directory (issue #228)
        open(joinpath(testdir, "A228.jl"), "w") do io
            println(io, """
                        module A228
                        using B228
                        export f228
                        f228(x) = 3 * g228(x)
                        end
                        """)
        end
        open(joinpath(testdir, "B228.jl"), "w") do io
            println(io, """
                        module B228
                        export g228
                        g228(x) = 4x + 2
                        end
                        """)
        end
        using A228
        @test f228(3) == 42
        sleep(2.1)
        open(joinpath(testdir, "B228.jl"), "w") do io
            println(io, """
                        module B228
                        export g228
                        g228(x) = 4x + 1
                        end
                        """)
        end
        yry()
        @test f228(3) == 39
        rm_precompile("A228")
        rm_precompile("B228")

        pop!(LOAD_PATH)
    end

    # issue #131
    @testset "Base & stdlib file paths" begin
        @test isfile(Revise.basesrccache)
        targetfn = Base.Filesystem.path_separator * joinpath("good", "path", "mydir", "myfile.jl")
        @test Revise.fixpath("/some/bad/path/mydir/myfile.jl"; badpath="/some/bad/path", goodpath="/good/path") == targetfn
        @test Revise.fixpath("/some/bad/path/mydir/myfile.jl"; badpath="/some/bad/path/", goodpath="/good/path") == targetfn
        @test isfile(Revise.fixpath(Base.find_source_file("array.jl")))
        failedfiles = Tuple{String,String}[]
        for (mod,file) = Base._included_files
            fixedfile = Revise.fixpath(file)
            if !isfile(fixedfile)
                push!(failedfiles, (file, fixedfile))
            end
        end
        if !isempty(failedfiles)
            display(failedfiles)
        end
        @test isempty(failedfiles)
    end

    # issue #36
    @testset "@__FILE__" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "ModFILE", "src")
        mkpath(dn)
        open(joinpath(dn, "ModFILE.jl"), "w") do io
            println(io, """
module ModFILE

mf() = @__FILE__, 1

end
""")
        end
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using ModFILE
        @test ModFILE.mf() == (joinpath(dn, "ModFILE.jl"), 1)
        sleep(0.1)
        open(joinpath(dn, "ModFILE.jl"), "w") do io
            println(io, """
module ModFILE

mf() = @__FILE__, 2

end
""")
        end
        yry()
        @test ModFILE.mf() == (joinpath(dn, "ModFILE.jl"), 2)
        rm_precompile("ModFILE")
        pop!(LOAD_PATH)
    end

    # issue #8
    @testset "Module docstring" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "ModDocstring", "src")
        mkpath(dn)
        open(joinpath(dn, "ModDocstring.jl"), "w") do io
            println(io, """
" Ahoy! "
module ModDocstring

include("dependency.jl")

f() = 1

end
""")
        end
        open(joinpath(dn, "dependency.jl"), "w") do io
            println(io, "")
        end
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using ModDocstring
        sleep(2)
        @test ModDocstring.f() == 1
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Ahoy! "

        sleep(0.1)  # ensure watching is set up
        open(joinpath(dn, "ModDocstring.jl"), "w") do io
            println(io, """
" Ahoy! "
module ModDocstring

include("dependency.jl")

f() = 2

end
""")
        end
        yry()
        @test ModDocstring.f() == 2
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Ahoy! "

        open(joinpath(dn, "ModDocstring.jl"), "w") do io
            println(io, """
" Hello! "
module ModDocstring

include("dependency.jl")

f() = 3

end
""")
        end
        yry()
        @test ModDocstring.f() == 3
        ds = @doc(ModDocstring)
        @test get_docstring(ds) == "Hello! "
        rm_precompile("ModDocstring")
        pop!(LOAD_PATH)
    end

    @testset "Undef in docstrings" begin
        fn = Base.find_source_file("abstractset.jl")   # has lots of examples of """str""" func1, func2
        mexsold = Revise.parse_source(fn, Base)
        mexsnew = Revise.parse_source(fn, Base)
        odict = mexsold[Base]
        ndict = mexsnew[Base]
        for (k, v) in odict
            @test haskey(ndict, k)
        end
    end

    # issue #165
    @testset "Changing @inline annotations" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "PerfAnnotations", "src")
        mkpath(dn)
        open(joinpath(dn, "PerfAnnotations.jl"), "w") do io
            println(io, """
            module PerfAnnotations

            @inline hasinline(x) = x
            check_hasinline(x) = hasinline(x)

            @noinline hasnoinline(x) = x
            check_hasnoinline(x) = hasnoinline(x)

            notannot1(x) = x
            check_notannot1(x) = notannot1(x)

            notannot2(x) = x
            check_notannot2(x) = notannot2(x)

            end
            """)
        end
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using PerfAnnotations
        @test PerfAnnotations.check_hasinline(3) == 3
        @test PerfAnnotations.check_hasnoinline(3) == 3
        @test PerfAnnotations.check_notannot1(3) == 3
        @test PerfAnnotations.check_notannot2(3) == 3
        ci = code_typed(PerfAnnotations.check_hasinline, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_hasnoinline, Tuple{Int})[1].first
        @test length(ci.code) == 2 && ci.code[1].head == :invoke
        ci = code_typed(PerfAnnotations.check_notannot1, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_notannot2, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        sleep(0.1)
        open(joinpath(dn, "PerfAnnotations.jl"), "w") do io
            println(io, """
            module PerfAnnotations

            hasinline(x) = x
            check_hasinline(x) = hasinline(x)

            hasnoinline(x) = x
            check_hasnoinline(x) = hasnoinline(x)

            @inline notannot1(x) = x
            check_notannot1(x) = notannot1(x)

            @noinline notannot2(x) = x
            check_notannot2(x) = notannot2(x)

            end
            """)
        end
        yry()
        @test PerfAnnotations.check_hasinline(3) == 3
        @test PerfAnnotations.check_hasnoinline(3) == 3
        @test PerfAnnotations.check_notannot1(3) == 3
        @test PerfAnnotations.check_notannot2(3) == 3
        ci = code_typed(PerfAnnotations.check_hasinline, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_hasnoinline, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_notannot1, Tuple{Int})[1].first
        @test length(ci.code) == 1 && ci.code[1] == Expr(:return, Core.SlotNumber(2))
        ci = code_typed(PerfAnnotations.check_notannot2, Tuple{Int})[1].first
        @test length(ci.code) == 2 && ci.code[1].head == :invoke
        rm_precompile("PerfAnnotations")

        pop!(LOAD_PATH)
    end

    @testset "Revising macros" begin
        # issue #174
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "MacroRevision", "src")
        mkpath(dn)
        open(joinpath(dn, "MacroRevision.jl"), "w") do io
            println(io, """
            module MacroRevision
            macro change(foodef)
                foodef.args[2].args[2] = 1
                esc(foodef)
            end
            @change foo(x) = 0
            end
            """)
        end
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using MacroRevision
        @test MacroRevision.foo("hello") == 1

        sleep(0.1)
        open(joinpath(dn, "MacroRevision.jl"), "w") do io
            println(io, """
            module MacroRevision
            macro change(foodef)
                foodef.args[2].args[2] = 2
                esc(foodef)
            end
            @change foo(x) = 0
            end
            """)
        end
        yry()
        @test MacroRevision.foo("hello") == 1
        revise(MacroRevision)
        @test MacroRevision.foo("hello") == 2

        sleep(0.1)
        open(joinpath(dn, "MacroRevision.jl"), "w") do io
            println(io, """
            module MacroRevision
            macro change(foodef)
                foodef.args[2].args[2] = 3
                esc(foodef)
            end
            @change foo(x) = 0
            end
            """)
        end
        yry()
        @test MacroRevision.foo("hello") == 2
        revise(MacroRevision)
        @test MacroRevision.foo("hello") == 3
        rm_precompile("MacroRevision")
        pop!(LOAD_PATH)
    end

    @testset "More arg-modifying macros" begin
        # issue #183
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "ArgModMacros", "src")
        mkpath(dn)
        open(joinpath(dn, "ArgModMacros.jl"), "w") do io
            println(io, """
            module ArgModMacros

            using EponymTuples

            const revision = Ref(0)

            function hyper_loglikelihood(@eponymargs(μ, σ, LΩ), @eponymargs(w̃s, α̃s, β̃s))
                revision[] = 1
                loglikelihood_normal(@eponymtuple(μ, σ, LΩ), vcat(w̃s, α̃s, β̃s))
            end

            loglikelihood_normal(@eponymargs(μ, σ, LΩ), stuff) = stuff

            end
            """)
        end
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using ArgModMacros
        @test ArgModMacros.hyper_loglikelihood((μ=1, σ=2, LΩ=3), (w̃s=4, α̃s=5, β̃s=6)) == [4,5,6]
        @test ArgModMacros.revision[] == 1
        sleep(0.1)
        open(joinpath(dn, "ArgModMacros.jl"), "w") do io
            println(io, """
            module ArgModMacros

            using EponymTuples

            const revision = Ref(0)

            function hyper_loglikelihood(@eponymargs(μ, σ, LΩ), @eponymargs(w̃s, α̃s, β̃s))
                revision[] = 2
                loglikelihood_normal(@eponymtuple(μ, σ, LΩ), vcat(w̃s, α̃s, β̃s))
            end

            loglikelihood_normal(@eponymargs(μ, σ, LΩ), stuff) = stuff

            end
            """)
        end
        yry()
        @test ArgModMacros.hyper_loglikelihood((μ=1, σ=2, LΩ=3), (w̃s=4, α̃s=5, β̃s=6)) == [4,5,6]
        @test ArgModMacros.revision[] == 2
        rm_precompile("ArgModMacros")
        pop!(LOAD_PATH)
    end

    @testset "Line numbers" begin
        # issue #27
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        modname = "LineNumberMod"
        dn = joinpath(testdir, modname, "src")
        mkpath(dn)
        open(joinpath(dn, modname*".jl"), "w") do io
            println(io, """
module $modname
include("incl.jl")
end
""")
        end
        open(joinpath(dn, "incl.jl"), "w") do io
            println(io, """
0
0
1
2
3
4
5
6
7
8


function foo(x)
    return x+5
end

foo(y::Int) = y-51
""")
        end
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using LineNumberMod
        lines = Int[]
        files = String[]
        for m in methods(LineNumberMod.foo)
            push!(files, String(m.file))
            push!(lines, m.line)
        end
        @test all(f->endswith(string(f), "incl.jl"), files)
        sleep(0.1)  # ensure watching is set up
        open(joinpath(dn, "incl.jl"), "w") do io
            println(io, """
0
0
1
2
3
4
5
6
7
8


function foo(x)
    return x+6
end

foo(y::Int) = y-51
""")
        end
        yry()
        for m in methods(LineNumberMod.foo)
            @test endswith(string(m.file), "incl.jl")
            @test m.line ∈ lines
        end
        rm_precompile("LineNumberMod")
        pop!(LOAD_PATH)
    end

    # Issue #43
    @testset "New submodules" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "Submodules", "src")
        mkpath(dn)
        open(joinpath(dn, "Submodules.jl"), "w") do io
            println(io, """
module Submodules
f() = 1
end
""")
        end
        sleep(2.1) # so the defining files are old enough not to trigger mtime criterion
        @eval using Submodules
        @test Submodules.f() == 1
        sleep(0.1)  # ensure watching is set up
        open(joinpath(dn, "Submodules.jl"), "w") do io
            println(io, """
module Submodules
f() = 1
module Sub
g() = 2
end
end
""")
        end
        yry()
        @test Submodules.f() == 1
        @test Submodules.Sub.g() == 2
        rm_precompile("Submodules")
        pop!(LOAD_PATH)
    end

    @testset "Method deletion" begin
        Core.eval(Base, :(revisefoo(x::Float64) = 1)) # to test cross-module method scoping
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "MethDel", "src")
        mkpath(dn)
        open(joinpath(dn, "MethDel.jl"), "w") do io
            println(io, """
__precompile__(false)   # "clean" Base doesn't have :revisefoo
module MethDel
f(x) = 1
f(x::Int) = 2
g(x::Vector{T}, y::T) where T = 1
g(x::Array{T,N}, y::T) where N where T = 2
g(::Array, ::Any) = 3
h(x::Array{T}, y::T) where T = g(x, y)
k(::Int; badchoice=1) = badchoice
Base.revisefoo(x::Int) = 2
struct Private end
Base.revisefoo(::Private) = 3

dfltargs(x::Int8, y::Int=0, z::Float32=1.0f0) = x+y+z

hasmacro1(@nospecialize(x)) = x
hasmacro2(@nospecialize(x::Int)) = x
hasmacro3(@nospecialize(x::Int), y::Float64) = x

hasdestructure1(x, (count, name)) = name^count
hasdestructure2(x, (count, name)::Tuple{Int,Any}) = name^count

struct A end
struct B end

checkunion(a::Union{Nothing, A}) = 1

methgensym(::Vector{<:Integer}) = 1

mapf(fs, x) = (fs[1](x), mapf(Base.tail(fs), x)...)
mapf(::Tuple{}, x) = ()

end
""")
        end
        @eval using MethDel
        @test MethDel.f(1.0) == 1
        @test MethDel.f(1) == 2
        @test MethDel.g(rand(3), 1.0) == 1
        @test MethDel.g(rand(3, 3), 1.0) == 2
        @test MethDel.g(Int[], 1.0) == 3
        @test MethDel.h(rand(3), 1.0) == 1
        @test MethDel.k(1) == 1
        @test MethDel.k(1; badchoice=2) == 2
        @test MethDel.hasmacro1(1) == 1
        @test MethDel.hasmacro2(1) == 1
        @test MethDel.hasmacro3(1, 0.0) == 1
        @test MethDel.hasdestructure1(0, (3, "hi")) == "hihihi"
        @test MethDel.hasdestructure2(0, (3, "hi")) == "hihihi"
        @test Base.revisefoo(1.0) == 1
        @test Base.revisefoo(1) == 2
        @test Base.revisefoo(MethDel.Private()) == 3
        @test MethDel.dfltargs(Int8(2)) == 3.0f0
        @test MethDel.dfltargs(Int8(2), 5) == 8.0f0
        @test MethDel.dfltargs(Int8(2), 5, -17.0f0) == -10.0f0
        @test MethDel.checkunion(nothing) == 1
        @test MethDel.methgensym([1]) == 1
        @test_throws MethodError MethDel.methgensym([1.0])
        @test MethDel.mapf((x->x+1, x->x+0.1), 3) == (4, 3.1)
        sleep(0.1)  # ensure watching is set up
        open(joinpath(dn, "MethDel.jl"), "w") do io
            println(io, """
module MethDel
f(x) = 1
g(x::Array{T,N}, y::T) where N where T = 2
h(x::Array{T}, y::T) where T = g(x, y)
k(::Int; goodchoice=-1) = goodchoice
dfltargs(x::Int8, yz::Tuple{Int,Float32}=(0,1.0f0)) = x+yz[1]+yz[2]

struct A end
struct B end

checkunion(a::Union{Nothing, B}) = 2

methgensym(::Vector{<:Real}) = 1

mapf(fs::F, x) where F = (fs[1](x), mapf(Base.tail(fs), x)...)
mapf(::Tuple{}, x) = ()

end
""")
        end
        yry()
        @test MethDel.f(1.0) == 1
        @test MethDel.f(1) == 1
        @test MethDel.g(rand(3), 1.0) == 2
        @test MethDel.g(rand(3, 3), 1.0) == 2
        @test_throws MethodError MethDel.g(Int[], 1.0)
        @test MethDel.h(rand(3), 1.0) == 2
        @test_throws MethodError MethDel.k(1; badchoice=2)
        @test MethDel.k(1) == -1
        @test MethDel.k(1; goodchoice=10) == 10
        @test_throws MethodError MethDel.hasmacro1(1)
        @test_throws MethodError MethDel.hasmacro2(1)
        @test_throws MethodError MethDel.hasmacro3(1, 0.0)
        @test_throws MethodError MethDel.hasdestructure1(0, (3, "hi"))
        @test_throws MethodError MethDel.hasdestructure2(0, (3, "hi"))
        @test Base.revisefoo(1.0) == 1
        @test_throws MethodError Base.revisefoo(1)
        @test_throws MethodError Base.revisefoo(MethDel.Private())
        @test MethDel.dfltargs(Int8(2)) == 3.0f0
        @test MethDel.dfltargs(Int8(2), (5,-17.0f0)) == -10.0f0
        @test_throws MethodError MethDel.dfltargs(Int8(2), 5) == 8.0f0
        @test_throws MethodError MethDel.dfltargs(Int8(2), 5, -17.0f0) == -10.0f0
        @test MethDel.checkunion(nothing) == 2
        @test MethDel.methgensym([1]) == 1
        @test MethDel.methgensym([1.0]) == 1
        @test length(methods(MethDel.methgensym)) == 1
        @test MethDel.mapf((x->x+1, x->x+0.1), 3) == (4, 3.1)
        @test length(methods(MethDel.mapf)) == 2

        Base.delete_method(first(methods(Base.revisefoo)))

        # Test for specificity in deletion
        ex1 = :(methspecificity(x::Int) = 1)
        ex2 = :(methspecificity(x::Integer) = 2)
        Core.eval(ReviseTestPrivate, ex1)
        Core.eval(ReviseTestPrivate, ex2)
        exsig1 = Revise.RelocatableExpr(ex1)=>[Tuple{typeof(ReviseTestPrivate.methspecificity),Int}]
        exsig2 = Revise.RelocatableExpr(ex2)=>[Tuple{typeof(ReviseTestPrivate.methspecificity),Integer}]
        f_old, f_new = Revise.ExprsSigs(exsig1, exsig2), Revise.ExprsSigs(exsig2)
        Revise.delete_missing!(f_old, f_new)
        m = @which ReviseTestPrivate.methspecificity(1)
        @test m.sig.parameters[2] === Integer
        Revise.delete_missing!(f_old, f_new)
        m = @which ReviseTestPrivate.methspecificity(1)
        @test m.sig.parameters[2] === Integer
    end

    @testset "Revision errors" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "RevisionErrors", "src")
        mkpath(dn)
        open(joinpath(dn, "RevisionErrors.jl"), "w") do io
            println(io, """
            module RevisionErrors
            f(x) = 1
            end
            """)
        end
        @eval using RevisionErrors
        @test RevisionErrors.f(0) == 1
        sleep(0.1)
        open(joinpath(dn, "RevisionErrors.jl"), "w") do io
            println(io, """
            module RevisionErrors
            f{x) = 2
            end
            """)
        end
        logs, _ = Test.collect_test_logs() do
            yry()
        end
        rec = logs[1]
        @test startswith(rec.message, "Failed to revise")
        @test occursin("missing comma", rec.message)

        rm_precompile("RevisionErrors")
    end

    @testset "get_def" begin
        testdir = randtmp()
        mkdir(testdir)
        push!(to_remove, testdir)
        push!(LOAD_PATH, testdir)
        dn = joinpath(testdir, "GetDef", "src")
        mkpath(dn)
        open(joinpath(dn, "GetDef.jl"), "w") do io
            println(io, """
            module GetDef

            f(x) = 1
            f(v::AbstractVector) = 2
            f(v::AbstractVector{<:Integer}) = 3

            end
            """)
        end
        @eval using GetDef
        @test GetDef.f(1.0) == 1
        @test GetDef.f([1.0]) == 2
        @test GetDef.f([1]) == 3
        m = @which GetDef.f([1])
        ex = Revise.RelocatableExpr(definition(m))
        @test ex isa Revise.RelocatableExpr
        @test isequal(ex, Revise.RelocatableExpr(:(f(v::AbstractVector{<:Integer}) = 3)))

        rm_precompile("GetDef")

        # This method identifies itself as originating from @irrational, defined in Base, but
        # the module of the method is listed as Base.MathConstants.
        m = @which Float32(π)
        @test definition(m) isa Expr
    end

    @testset "Pkg exclusion" begin
        push!(Revise.dont_watch_pkgs, :Example)
        push!(Revise.silence_pkgs, :Example)
        @eval import Example
        id = Base.PkgId(Example)
        @test !haskey(Revise.pkgdatas, id)
        # Ensure that silencing works
        sfile = Revise.silencefile[]  # remember the original
        try
            sfiletemp = tempname()
            Revise.silencefile[] = sfiletemp
            Revise.silence("GSL")
            @test isfile(sfiletemp)
            pkgs = readlines(sfiletemp)
            @test any(p->p=="GSL", pkgs)
            rm(sfiletemp)
        finally
            Revise.silencefile[] = sfile
        end
        pop!(LOAD_PATH)
    end

    @testset "Manual track" begin
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        open(srcfile, "w") do io
            print(io, """
revise_f(x) = 1
""")
        end
        includet(srcfile)
        @test revise_f(10) == 1
        @test length(signatures_at(srcfile, 1)) == 1
        sleep(0.1)
        open(srcfile, "w") do io
            print(io, """
revise_f(x) = 2
""")
        end
        yry()
        @test revise_f(10) == 2
        push!(to_remove, srcfile)

        # Do it again with a relative path
        curdir = pwd()
        cd(tempdir())
        srcfile = randtmp()*".jl"
        open(srcfile, "w") do io
            print(io, """
        revise_floc(x) = 1
        """)
        end
        include(joinpath(pwd(), srcfile))
        @test revise_floc(10) == 1
        Revise.track(srcfile)
        sleep(0.1)
        open(srcfile, "w") do io
            print(io, """
        revise_floc(x) = 2
        """)
        end
        yry()
        @test revise_floc(10) == 2
        push!(to_remove, joinpath(tempdir(), srcfile))
        cd(curdir)
    end

    @testset "Auto-track user scripts" begin
        srcfile = joinpath(tempdir(), randtmp()*".jl")
        push!(to_remove, srcfile)
        open(srcfile, "w") do io
            println(io, "revise_g() = 1")
        end
        # By default user scripts are not tracked
        include(srcfile)
        yry()
        @test revise_g() == 1
        sleep(0.1)
        open(srcfile, "w") do io
            println(io, "revise_g() = 2")
        end
        yry()
        @test revise_g() == 1
        # Turn on tracking of user scripts
        empty!(Revise.included_files)  # don't track files already loaded (like this one)
        Revise.tracking_Main_includes[] = true
        try
            srcfile = joinpath(tempdir(), randtmp()*".jl")
            push!(to_remove, srcfile)
            open(srcfile, "w") do io
                println(io, "revise_g() = 1")
            end
            include(srcfile)
            yry()
            @test revise_g() == 1
            sleep(0.1)
            open(srcfile, "w") do io
                println(io, "revise_g() = 2")
            end
            yry()
            @test revise_g() == 2
        finally
            Revise.tracking_Main_includes[] = false  # restore old behavior
        end
    end

    @testset "Distributed" begin
        newprocs = addprocs(2)
        Revise.init_worker.(newprocs)
        allworkers = [myid(); newprocs]
        dirname = randtmp()
        mkdir(dirname)
        @everywhere push_LOAD_PATH!(dirname) = push!(LOAD_PATH, dirname)  # Don't want to share this LOAD_PATH
        for p in allworkers
            remotecall_wait(push_LOAD_PATH!, p, dirname)
        end
        push!(to_remove, dirname)
        modname = "ReviseDistributed"
        dn = joinpath(dirname, modname, "src")
        mkpath(dn)
        open(joinpath(dn, modname*".jl"), "w") do io
            println(io, """
module ReviseDistributed

f() = π
g(::Int) = 0

end
""")
        end
        sleep(2.1)   # so the defining files are old enough not to trigger mtime criterion
        using ReviseDistributed
        @everywhere using ReviseDistributed
        for p in allworkers
            @test remotecall_fetch(ReviseDistributed.f, p)    == π
            @test remotecall_fetch(ReviseDistributed.g, p, 1) == 0
        end
        sleep(0.1)
        open(joinpath(dn, modname*".jl"), "w") do io
            println(io, """
module ReviseDistributed

f() = 3.0

end
""")
        end
        yry()
        sleep(1.0)
        @test_throws MethodError ReviseDistributed.g(1)
        for p in allworkers
            @test remotecall_fetch(ReviseDistributed.f, p) == 3.0
            @test_throws RemoteException remotecall_fetch(ReviseDistributed.g, p, 1)
        end
        rmprocs(allworkers[2:3]...; waitfor=10)
        rm_precompile("ReviseDistributed")
        pop!(LOAD_PATH)
    end

    @testset "Git" begin
        # if haskey(ENV, "CI")   # if we're doing CI testing (Travis, Appveyor, etc.)
        #     # First do a full git checkout of a package (we'll use Revise itself)
        #     @warn "checking out a development copy of Revise for testing purposes"
        #     pkg = Pkg.develop("Revise")
        # end
        loc = Base.find_package("Revise")
        if occursin("dev", loc)
            repo, path = Revise.git_repo(loc)
            @test repo != nothing
            files = Revise.git_files(repo)
            @test "README.md" ∈ files
            src = Revise.git_source(loc, "946d588328c2eb5fe5a56a21b4395379e41092e0")
            @test startswith(src, "__precompile__")
            src = Revise.git_source(loc, "eae5e000097000472280e6183973a665c4243b94") # 2nd commit in Revise's history
            @test src == "module Revise\n\n# package code goes here\n\nend # module\n"
        else
            @warn "skipping git tests because Revise is not under development"
        end
        # Issue #135
        if !Sys.iswindows()
            randdir = randtmp()
            modname = "ModuleWithNewFile"
            push!(to_remove, randdir)
            push!(LOAD_PATH, randdir)
            randdir = joinpath(randdir, modname)
            mkpath(joinpath(randdir, "src"))
            mainjl = joinpath(randdir, "src", modname*".jl")
            LibGit2.with(LibGit2.init(randdir)) do repo
                open(mainjl, "w") do io
                    println(io, """
                    module $modname
                    end
                    """)
                end
                LibGit2.add!(repo, joinpath("src", modname*".jl"))
                test_sig = LibGit2.Signature("TEST", "TEST@TEST.COM", round(time(); digits=0), 0)
                LibGit2.commit(repo, "New file test"; author=test_sig, committer=test_sig)
            end
            @eval using $(Symbol(modname))
            mod = @eval $(Symbol(modname))
            id = Base.PkgId(mod)
            # id = Base.PkgId(Main)
            extrajl = joinpath(randdir, "src", "extra.jl")
            open(extrajl, "w") do io
                println(io, """
                println("extra")
                """)
            end
            sleep(0.1)
            open(mainjl, "w") do io
                println(io, """
                module $modname
                include("extra.jl")
                end
                """)
            end
            repo = LibGit2.GitRepo(randdir)
            LibGit2.add!(repo, joinpath("src", "extra.jl"))
            logs, _ = Test.collect_test_logs() do
                Revise.track_subdir_from_git(id, joinpath(randdir, "src"); commit="HEAD")
            end
            yry()
            @test Revise.hasfile(Revise.pkgdatas[id], mainjl)
            @test startswith(logs[end].message, "skipping src/extra.jl")
            rm_precompile("ModuleWithNewFile")
            pop!(LOAD_PATH)
        end
    end

    @testset "Recipes" begin
        # Tracking Base
        Revise.track(Base)
        id = Base.PkgId(Base)
        pkgdata = Revise.pkgdatas[id]
        @test any(k->endswith(k, "number.jl"), Revise.srcfiles(pkgdata))
        @test length(filter(k->endswith(k, "file.jl"), Revise.srcfiles(pkgdata))) == 1
        m = @which show([1,2,3])
        @test definition(m) isa Expr
        m = @which redirect_stdout()
        @test definition(m).head == :function

        # Tracking stdlibs
        Revise.track(Unicode)
        id = Base.PkgId(Unicode)
        pkgdata = Revise.pkgdatas[id]
        @test any(k->endswith(k, "Unicode.jl"), Revise.srcfiles(pkgdata))
        m = first(methods(Unicode.isassigned))
        @test definition(m) isa Expr
        @test isfile(whereis(m)[1])

        # Submodule of Pkg (note that package is developed outside the
        # Julia repo, this tests new cases)
        id = Revise.get_tracked_id(Pkg.Types)
        pkgdata = Revise.pkgdatas[id]
        @test definition(first(methods(Pkg.API.add))) isa Expr

        # Test that we skip over files that don't end in ".jl"
        logs, _ = Test.collect_test_logs() do
            Revise.track(REPL)
        end
        @test isempty(logs)

        Revise.get_tracked_id(Core)   # just test that this doesn't error

        # Determine whether a git repo is available. Travis & Appveyor do not have this.
        # FIXME restore these tests
        # repo, path = Revise.git_repo(Revise.juliadir)
        # if repo != nothing
        #     # Tracking Core.Compiler
        #     Revise.track(Core.Compiler)
        #     id = Base.PkgId(Core.Compiler)
        #     pkgdata = Revise.pkgdatas[id]
        #     @test any(k->endswith(k, "compiler.jl"), Revise.srcfiles(pkgdata))
        #     m = first(methods(Core.Compiler.typeinf_code))
        #     @test definition(m) isa Expr
        # else
        #     @test_throws Revise.GitRepoException Revise.track(Core.Compiler)
        #     @warn "skipping Core.Compiler tests due to lack of git repo"
        # end
    end

    @testset "Switching free/dev" begin
        function make_a2d(path, val, mode="r")
            # Create a new "read-only package" (which mimics how Pkg works when you `add` a package)
            pkgpath = joinpath(path, "A2D")
            srcpath = joinpath(pkgpath, "src")
            mkpath(srcpath)
            filepath = joinpath(srcpath, "A2D.jl")
            open(filepath, "w") do io
                println(io, """
                        module A2D
                        f() = $val
                        end
                        """)
            end
            chmod(filepath, mode=="r" ? 0o100444 : 0o100644)
            return pkgpath
        end
        # Create a new package depot
        depot = mktempdir()
        old_depots = copy(DEPOT_PATH)
        empty!(DEPOT_PATH)
        push!(DEPOT_PATH, depot)
        # Skip cloning the General registry since that is slow and unnecessary
        registries = Pkg.Types.DEFAULT_REGISTRIES
        old_registries = copy(registries)
        empty!(registries)
        # Ensure we start fresh with no dependencies
        old_project = Base.ACTIVE_PROJECT[]
        Base.ACTIVE_PROJECT[] = joinpath(depot, "environments", "v$(VERSION.major).$(VERSION.minor)", "Project.toml")
        mkpath(dirname(Base.ACTIVE_PROJECT[]))
        open(Base.ACTIVE_PROJECT[], "w") do io
            println(io, "[deps]")
        end
        ropkgpath = make_a2d(depot, 1)
        Pkg.REPLMode.do_cmd(Pkg.REPLMode.minirepl[], "dev $ropkgpath"; do_rethrow=true)  # like pkg> dev $pkgpath; unfortunately, Pkg.develop(pkgpath) doesn't work
        @eval using A2D
        @test Base.invokelatest(A2D.f) == 1
        for dir in keys(Revise.watched_files)
            @test !startswith(dir, ropkgpath)
        end
        devpath = joinpath(depot, "dev")
        mkpath(devpath)
        mfile = Revise.manifest_file()
        schedule(Task(Revise.Rescheduler(Revise.watch_manifest, (mfile,))))
        sleep(2.1)
        pkgdevpath = make_a2d(devpath, 2, "w")
        Pkg.REPLMode.do_cmd(Pkg.REPLMode.minirepl[], "dev $pkgdevpath"; do_rethrow=true)
        yry()
        @test Base.invokelatest(A2D.f) == 2
        Pkg.REPLMode.do_cmd(Pkg.REPLMode.minirepl[], "dev $ropkgpath"; do_rethrow=true)
        sleep(2.1)
        yry()
        @test Base.invokelatest(A2D.f) == 1
        for dir in keys(Revise.watched_files)
            @test !startswith(dir, ropkgpath)
        end

        # Restore internal Pkg data
        empty!(DEPOT_PATH)
        append!(DEPOT_PATH, old_depots)
        for pr in old_registries
            push!(registries, pr)
        end
        Base.ACTIVE_PROJECT[] = old_project

        push!(to_remove, depot)
    end

    GC.gc(); GC.gc()

    @testset "Cleanup" begin
        logs, _ = Test.collect_test_logs() do
            warnfile = randtmp()
            open(warnfile, "w") do io
                redirect_stderr(io) do
                    for name in to_remove
                        try
                            rm(name; force=true, recursive=true)
                            deleteat!(LOAD_PATH, findall(LOAD_PATH .== name))
                        catch
                        end
                    end
                    try yry() catch end
                end
            end
            if !Sys.isapple()
                @test occursin("is not an existing directory", read(warnfile, String))
            end
            rm(warnfile)
        end
    end

end

GC.gc(); GC.gc(); GC.gc()   # work-around for https://github.com/JuliaLang/julia/issues/28306

@testset "Base signatures" begin
    # Using the extensive repository of code in Base as a testbed
    include("sigtest.jl")
end
