# Driver.
@dynamo function (mx::ExecutionContext)(a...)
    ir = IR(a...)
    ir == nothing && return
    recurse!(ir)
    return ir
end

# The wondrous worlds of contexts.

abstract type GenerateContext <: ExecutionContext end
mutable struct UnconstrainedGenerateContext{T <: Trace} <: GenerateContext
    tr::T
    UnconstrainedGenerateContext(tr::T) where T <: Trace = new{T}(tr)
end
Generate(tr::Trace) = UnconstrainedGenerateContext(tr)

mutable struct ConstrainedGenerateContext{T <: Trace, K <: ConstrainedSelection} <: GenerateContext
    tr::T
    select::K
    visited::VisitedSelection
    ConstrainedGenerateContext(tr::T, select::K) where {T <: Trace, K <: ConstrainedSelection} = new{T, K}(tr, select, VisitedSelection())
end
Generate(tr::Trace, select::ConstrainedSelection) = ConstrainedGenerateContext(tr, select)

mutable struct ProposalContext{T <: Trace} <: ExecutionContext
    tr::T
    ProposalContext(tr::T) where T <: Trace = new{T}(tr)
end
Propose(tr::Trace) = ProposalContext(tr)

mutable struct UpdateContext{T <: Trace, K <: ConstrainedSelection} <: ExecutionContext
    prev::T
    tr::T
    select::K
    visited::VisitedSelection
    UpdateContext(tr::T, select::K) where {T <: Trace, K <: ConstrainedSelection} = new{T, K}(tr, Trace(), select, VisitedSelection())
end
Update(tr::Trace, select) = UpdateContext(tr, select)

mutable struct RegenerateContext{T <: Trace, L <: UnconstrainedSelection} <: ExecutionContext
    prev::T
    tr::T
    select::L
    visited::VisitedSelection
    function RegenerateContext(tr::T, sel::Vector{Address}) where T <: Trace
        un_sel = selection(sel)
        new{T, typeof(un_sel)}(tr, Trace(), un_sel, VisitedSelection())
    end
    function RegenerateContext(tr::T, sel::L) where {T <: Trace, L <: UnconstrainedSelection}
        new{T, L}(tr, Trace(), sel, VisitedSelection())
    end
end
Regenerate(tr::Trace, sel::Vector{Address}) = RegenerateContext(tr, sel)
Regenerate(tr::Trace, sel::UnconstrainedSelection) = RegenerateContext(tr, sel)

mutable struct ScoreContext{K <: ConstrainedSelection} <: ExecutionContext
    score::Float64
    select::K
    function Score(obs::Vector{Tuple{K, P}}) where {P, K <: Union{Symbol, Pair}}
        c_sel = selection(obs)
        new{typeof(c_sel)}(0.0, c_sel)
    end
    ScoreContext(obs::K) where {K <: ConstrainedSelection} = new{K}(0.0, obs)
end
Score(obs::Vector) = ScoreContext(obs)
Score(obs::ConstrainedSelection) = ScoreContext(sel)

# Choice sites.

@inline function (ctx::UnconstrainedGenerateContext)(call::typeof(rand), 
                                                     addr::T, 
                                                     d::Distribution{K}) where {T <: Address, K}
    s = rand(d)
    ctx.tr.chm[addr] = ChoiceSite(logpdf(d, s), s)
    return s
end

@inline function (ctx::ConstrainedGenerateContext)(call::typeof(rand), 
                                                   addr::T, 
                                                   d::Distribution{K}) where {T <: Address, K}
    if haskey(ctx.select.query, addr)
        s = ctx.select.query[addr]
        score = logpdf(d, s)
        ctx.tr.chm[addr] = ChoiceSite(score, s)
        ctx.tr.score += score
        push!(ctx.visited, addr)
    else
        s = rand(d)
        ctx.tr.chm[addr] = ChoiceSite(logpdf(d, s), s)
        push!(ctx.visited, addr)
    end
    return s
end

@inline function (ctx::ProposalContext)(call::typeof(rand), 
                                        addr::T, 
                                        d::Distribution{K}) where {T <: Address, K}
    s = rand(d)
    score = logpdf(d, s)
    ctx.tr.chm[addr] = ChoiceSite(score, s)
    ctx.tr.score += score
    return s

end

@inline function (ctx::RegenerateContext)(call::typeof(rand), 
                                          addr::T, 
                                          d::Distribution{K}) where {T <: Address, K}

    # Check if in previous trace's choice map.
    in_prev_chm = haskey(ctx.prev.chm, addr)
    in_prev_chm && begin
        prev = ctx.prev.chm[addr]
        prev_val = prev.val
        prev_score = prev.score
    end

    # Check if in selection in meta.
    in_sel = haskey(ctx.select.query, addr)

    ret = rand(d)
    in_prev_chm && !in_sel && begin
        ret = prev_val
    end

    score = logpdf(d, ret)
    in_prev_chm && !in_sel && begin
        ctx.tr.score += score - prev_score
    end
    ctx.tr.chm[addr] = ChoiceSite(score, ret)
    push!(ctx.visited, addr)
    ret
end

@inline function (ctx::UpdateContext)(call::typeof(rand), 
                                      addr::T, 
                                      d::Distribution{K}) where {T <: Address, K}

    # Check if in previous trace's choice map.
    in_prev_chm = haskey(ctx.prev.chm, addr)
    in_prev_chm && begin
        prev = ctx.prev.chm[addr]
        prev_ret = prev.val
        prev_score = prev.score
    end

    # Check if in selection.
    in_selection = haskey(ctx.select.query, addr)

    # Ret.
    if in_selection
        ret = ctx.select.query[addr]
    elseif in_prev_chm
        ret = prev_ret
    else
        ret = rand(d)
    end

    # Update.
    score = logpdf(d, ret)
    if in_prev_chm
        ctx.tr.score += score - prev_score
    elseif in_selection
        ctx.tr.score += score
    end
    ctx.tr.chm[addr] = ChoiceSite(score, ret)

    push!(ctx.visited, addr)
    return ret
end

@inline function (ctx::ScoreContext)(call::typeof(rand), 
                                     addr::T, 
                                     d::Distribution{K}) where {T <: Address, K}

    haskey(ctx.select.query, addr) || error("ScoreError: constrained selection must provide constraints for all possible addresses in trace. Missing at address $addr.") && begin
        val = ctx.select.query[addr]
    end
    ctx.score += logpdf(d, val)
    return val
end

# Call sites.

@inline function (ctx::UnconstrainedGenerateContext)(c::typeof(rand),
                                                     addr::T,
                                                     call::Function,
                                                     args...) where T <: Address
    ug_ctx = UnconstrainedGenerateContext(Trace())
    ret = ug_ctx(call, args...)
    ctx.tr.chm[addr] = CallSite(ug_ctx.tr,
                                call, 
                                args, 
                                ret)
    return ret
end

@inline function (ctx::ConstrainedGenerateContext)(c::typeof(rand),
                                                   addr::T,
                                                   call::Function,
                                                   args...) where T <: Address

    cg_ctx = ConstrainedGenerateContext(Trace(), ctx.select[addr])
    ret = cg_ctx(call, args...)
    ctx.tr.chm[addr] = CallSite(cg_ctx.tr,
                                call, 
                                args, 
                                ret)
    ctx.visited.tree[addr] = cg_ctx.visited
    return ret
end

@inline function (ctx::ProposalContext)(c::typeof(rand),
                                        addr::T,
                                        call::Function,
                                        args...) where T <: Address

    p_ctx = Propose(Trace())
    ret = p_ctx(call, args...)
    ctx.tr.chm[addr] = CallSite(p_ctx.tr, 
                                call, 
                                args, 
                                ret)
    return ret
end

@inline function (ctx::UpdateContext)(c::typeof(rand),
                                      addr::T,
                                      call::Function,
                                      args...) where T <: Address
    u_ctx = Update(ctx.prev.chm[addr].trace, ctx.select[addr])
    ret = u_ctx(call, args...)
    ctx.tr.chm[addr] = CallSite(u_ctx.tr, 
                                call, 
                                args, 
                                ret)
    ctx.visited.tree[addr] = u_ctx.visited
    return ret
end

@inline function (ctx::RegenerateContext)(c::typeof(rand),
                                          addr::T,
                                          call::Function,
                                          args...) where T <: Address

    ur_ctx = Regenerate(ctx.prev.chm[addr].trace, ctx.select[addr])
    ret = ur_ctx(call, args...)
    ctx.tr.chm[addr] = CallSite(ur_ctx.tr, 
                                call, 
                                args, 
                                ret)
    ctx.visited.tree[addr] = ur_ctx.visited
    return ret
end

@inline function (ctx::ScoreContext)(c::typeof(rand),
                                     addr::T,
                                     call::Function,
                                     args...) where T <: Address

    s_ctx = Score(ctx.select[addr])
    ret = s_ctx(call, args...)
    return ret
end
