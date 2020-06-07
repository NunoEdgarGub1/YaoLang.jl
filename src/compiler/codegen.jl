export codegen, JuliaASTCodegenCtx

abstract type CompileCtx end
abstract type AbstractJuliaASTCtx <: CompileCtx end

const codegen_passes = Dict{Symbol, Function}()

struct JuliaASTCodegenCtx <: AbstractJuliaASTCtx
    stub_name::Any
    circuit::Symbol
    registers::Vector{Any}
    locations::Symbol
    ctrl_locations::Symbol
    codegen_pass::Vector{Any}
end

# generate to JuliaAST by default
codegen(ir::YaoIR) = codegen(JuliaASTCodegenCtx(ir), ir)

function codegen(ctx::JuliaASTCodegenCtx, ir)
    ex = Expr(:block)
    for pass in ctx.codegen_pass
        push!(ex.args, codegen_passes[pass](ctx, ir))
    end

    if ir.name isa Symbol
        push!(ex.args, :($(ir.name)))
    else
        push!(ex.args, nothing)
    end
    return ex
end

macro codegen(ex)
    defs = splitdef(ex)
    defs[:name] isa Symbol || throw(ParseError("@codegen expect function not callable or lambda function"))
    name = Symbol(:codegen_, defs[:name])
    quoted_name = QuoteNode(defs[:name])
    defs[:name] = name
    quote
        codegen_passes[$(quoted_name)] = $(esc(combinedef(defs)))
    end
end

flatten_locations(parent, x) = IRTools.xcall(Base, :getindex, parent, x)

function flatten_locations(pr, v, parent, x)
    loc = insert!(pr, v, Statement(to_locations(x)))
    return insert!(pr, v, Statement(flatten_locations(parent, loc)))
end

# merge location in runtime
merge_location_ex(l1, l2) = :(merge_locations($l1, $l2))
# merge literal location in compile time
merge_location_ex(l1::AbstractLocations, l2::AbstractLocations) = merge_locations(l1, l2)

function extract_closure_captured_variables!(pr::IRTools.Pipe, circ, ir::YaoIR)
    v = push!(pr, IRTools.xcall(Base, :getproperty, circ, QuoteNode(:free)))
    for (k, each) in enumerate(arguements(ir))
        x = push!(pr, IRTools.xcall(Base, :getfield, v, k))
        push!(pr, Statement(Expr(:(=), IRTools.Slot(each), x)))
    end
end

function scan_registers(register, stack::Vector, pr::IRTools.Pipe, v, st::Statement)
    if st.expr.args[2] === :new
        push!(stack, st.expr.args[3])
    elseif st.expr.args[2] === :prev
        pop!(stack)
    end

    if length(stack) == 1
        delete!(pr, v)
        return register
    else
        pr[v] = Statement(IRTools.Slot(first(stack)))
        return v
    end
end

function update_slots!(ssa::IRTools.IR, ir::YaoIR)
    for (v, st) in ssa
        if st.expr isa Expr
            args = Any[]
            for each in st.expr.args
                if each in arguements(ir)
                    push!(args, IRTools.Slot(each))
                else
                    push!(args, each)
                end
            end
            ssa[v] = Statement(st; expr=Expr(st.expr.head, args...))
        end
    end
    return ssa
end

@codegen function call(ctx::JuliaASTCodegenCtx, ir::YaoIR)
    defs = signature(ir)
    defs[:name] = :(::$(generic_circuit(ir.name)))
    defs[:body] = Expr(:call, circuit(ir.name), ctx.stub_name, Expr(:tuple, ir.args...))
    return combinedef(defs)
end

@codegen function evaluate(ctx::JuliaASTCodegenCtx, ir::YaoIR)
    defs = signature(ir)
    defs[:name] = GlobalRef(YaoLang, :evaluate)
    defs[:args] = Any[:(::$(generic_circuit(ir.name))), ir.args...]
    defs[:body] = Expr(:call, circuit(ir.name), ctx.stub_name, Expr(:tuple, ir.args...))
    return combinedef(defs)
end

@codegen function quantum_circuit(ctx::JuliaASTCodegenCtx, ir::YaoIR)
    empty!(ctx.registers)
    pr = IRTools.Pipe(ir.body)
    circ = IRTools.argument!(pr)
    register = IRTools.argument!(pr)
    locations = IRTools.argument!(pr)

    # extract arguements from closure
    extract_closure_captured_variables!(pr, circ, ir)

    for (v, st) in pr
        if is_quantum(st)
            head = st.expr.args[1]
            if head === :register
                register = scan_registers(register, ctx.registers, pr, v, st)
            elseif head in [:gate, :ctrl]
                locs = map(x->flatten_locations(pr, v, locations, x), st.expr.args[3:end])
                pr[v] = Statement(st;
                            expr=Expr(:call, st.expr.args[2],
                                register,
                                locs...,
                            )
                        )
            elseif head === :measure
                measure_ex = Expr(:call, GlobalRef(YaoAPI, :measure!))
                kwargs = first(st.expr.args[2])
                if kwargs.args[1] === :reset_to
                    push!(measure_ex.args, Expr(:call, ResetTo, kwargs.args[2]))
                elseif (kwargs.args[1] === :remove) && (kwargs.args[2] == true)
                    push!(measure_ex.args, Expr(:call, RemoveMeasured))
                end

                # contains operator
                if length(st.expr.args) == 4
                    push!(measure_ex.args, st.expr.args[3])
                    push!(measure_ex.args, register)
                end

                push!(measure_ex.args, register)
                loc = flatten_locations(pr, v, locations, st.expr.args[end])
                push!(measure_ex.args, loc)

                pr[v] = Statement(st; expr=measure_ex)
            else # reserved for extending keywords
                throw(ParseError("Invalid keyword: $head"))
            end
        end
    end

    def = Dict{Symbol, Any}()
    def[:name] = ctx.stub_name
    def[:args] = Any[
        :($(ctx.circuit)::$(YaoLang.Circuit)),
        :($(last(ctx.registers))::$AbstractRegister),
        :($(ctx.locations)::Locations),
    ]

    ssa = IRTools.finish(pr)
    update_slots!(ssa, ir)
    return build_codeinfo(ir.mod, def, ssa)
end

@codegen function ctrl_circuit(ctx::JuliaASTCodegenCtx, ir::YaoIR)
    hasmeasure(ir) && return :()
    empty!(ctx.registers)

    pr = IRTools.Pipe(ir.body)
    circ = IRTools.argument!(pr)
    register = IRTools.argument!(pr)
    locations = IRTools.argument!(pr)
    ctrl_locations = IRTools.argument!(pr)

    # extract arguements from closure
    extract_closure_captured_variables!(pr, circ, ir)

    for (v, st) in pr
        if is_quantum(st)
            head = st.expr.args[1]
            if head === :register
                register = scan_registers(register, ctx.registers, pr, v, st)
            elseif head === :gate
                locs = flatten_locations(pr, v, locations, st.expr.args[3])
                pr[v] = Statement(st;
                            expr=Expr(:call, st.expr.args[2],
                                register,
                                locs, ctrl_locations,
                            )
                        )
            elseif head === :ctrl
                locs = flatten_locations(pr, v, locations, st.expr.args[3])
                ctrl_locs = flatten_locations(pr, v, locations, st.expr.args[4])
                ctrl_locs = insert!(pr, v, merge_location_ex(ctrl_locations, ctrl_locs))
                pr[v] = Statement(st;
                            expr=Expr(:call, st.expr.args[2],
                                register,
                                locs, ctrl_locs,
                            )
                        )
            else # reserved for extending keywords
                throw(ParseError("Invalid keyword: $head"))
            end
        end
    end

    def = Dict{Symbol, Any}()
    def[:name] = ctx.stub_name
    def[:args] = Any[
        :($(ctx.circuit)::$(YaoLang.Circuit)),
        :($(last(ctx.registers))::$AbstractRegister),
        :($(ctx.locations)::$Locations),
        :($(ctx.ctrl_locations)::$CtrlLocations),
    ]

    ssa = IRTools.finish(pr)
    update_slots!(ssa, ir)
    return build_codeinfo(ir.mod, def, ssa)
end

@codegen function create_symbol(ctx::JuliaASTCodegenCtx, ir::YaoIR)
    :(Core.@__doc__ const $(ir.name) = $(generic_circuit(ir.name))())
end

@codegen function code_yao_runtime_stub(ctx::JuliaASTCodegenCtx, ir::YaoIR)
    def = Dict{Symbol,Any}()
    def[:name] = GlobalRef(YaoLang, :code_yao)
    def[:args] = Any[:(::$(generic_circuit(ir.name))), ir.args...]
    def[:body] = ir
    if !isempty(ir.whereparams)
        def[:whereparams] = ir.whereparams
    end
    return combinedef(def)
end

function JuliaASTCodegenCtx(ir::YaoIR, pass = collect(Any, keys(codegen_passes)))
    stub_name = gensym(ir.name)
    JuliaASTCodegenCtx(
        stub_name,
        gensym(:circ),
        Any[gensym(:register)],
        gensym(:locations),
        gensym(:ctrl_locations),
        pass,
    )
end
