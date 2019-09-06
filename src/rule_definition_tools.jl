# These are some macros (and supporting functions) to make it easier to define rules.

"""
    @scalar_rule(f(x₁, x₂, ...),
                 @setup(statement₁, statement₂, ...),
                 (∂f₁_∂x₁, ∂f₁_∂x₂, ...),
                 (∂f₂_∂x₁, ∂f₂_∂x₂, ...),
                 ...)

A convenience macro that generates simple scalar forward or reverse rules using
the provided partial derivatives. Specifically, generates the corresponding
methods for `frule` and `rrule`:

    function ChainRulesCore.frule(::typeof(f), x₁::Number, x₂::Number, ...)
        Ω = f(x₁, x₂, ...)
        \$(statement₁, statement₂, ...)
        return Ω, (NO_FIELDS_RULE,
                   Rule((Δx₁, Δx₂, ...) -> ∂f₁_∂x₁ * Δx₁ + ∂f₁_∂x₂ * Δx₂ + ...),
                   Rule((Δx₁, Δx₂, ...) -> ∂f₂_∂x₁ * Δx₁ + ∂f₂_∂x₂ * Δx₂ + ...),
                   ...)
    end

    function ChainRulesCore.rrule(::typeof(f), x₁::Number, x₂::Number, ...)
        Ω = f(x₁, x₂, ...)
        \$(statement₁, statement₂, ...)
        return Ω, (NO_FIELDS_RULE,
                   Rule((ΔΩ₁, ΔΩ₂, ...) -> ∂f₁_∂x₁ * ΔΩ₁ + ∂f₂_∂x₁ * ΔΩ₂ + ...),
                   Rule((ΔΩ₁, ΔΩ₂, ...) -> ∂f₁_∂x₂ * ΔΩ₁ + ∂f₂_∂x₂ * ΔΩ₂ + ...),
                   ...)
    end

If no type constraints in `f(x₁, x₂, ...)` within the call to `@scalar_rule` are
provided, each parameter in the resulting `frule`/`rrule` definition is given a
type constraint of `Number`.
Constraints may also be explicitly be provided to override the `Number` constraint,
e.g. `f(x₁::Complex, x₂)`, which will constrain `x₁` to `Complex` and `x₂` to
`Number`.

At present this does not support defining rules for closures/functors.
This the first returned rule, representing the derivative with respect to the
function itself, is always the `NO_FIELDS_RULE`.

The result of `f(x₁, x₂, ...)` is automatically bound to `Ω`. This
allows the primal result to be conveniently referenced (as `Ω`) within the
derivative/setup expressions.

The `@setup` argument can be elided if no setup code is need. In other
words:

    @scalar_rule(f(x₁, x₂, ...),
                 (∂f₁_∂x₁, ∂f₁_∂x₂, ...),
                 (∂f₂_∂x₁, ∂f₂_∂x₂, ...),
                 ...)

is equivalent to:

    @scalar_rule(f(x₁, x₂, ...),
                 @setup(nothing),
                 (∂f₁_∂x₁, ∂f₁_∂x₂, ...),
                 (∂f₂_∂x₁, ∂f₂_∂x₂, ...),
                 ...)

For examples, see ChainRulesCore' `rules` directory.

See also: [`frule`](@ref), [`rrule`](@ref), [`AbstractRule`](@ref)
"""
macro scalar_rule(call, maybe_setup, partials...)
    if Meta.isexpr(maybe_setup, :macrocall) && maybe_setup.args[1] == Symbol("@setup")
        setup_stmts = map(esc, maybe_setup.args[3:end])
    else
        setup_stmts = (nothing,)
        partials = (maybe_setup, partials...)
    end
    @assert Meta.isexpr(call, :call)
    f = esc(call.args[1])
    # Annotate all arguments in the signature as scalars
    inputs = map(call.args[2:end]) do arg
        esc(Meta.isexpr(arg, :(::)) ? arg : Expr(:(::), arg, :Number))
    end
    # Remove annotations and escape names for the call
    for (i, arg) in enumerate(call.args)
        if Meta.isexpr(arg, :(::))
            call.args[i] = esc(first(arg.args))
        else
            call.args[i] = esc(arg)
        end
    end
    if all(Meta.isexpr(partial, :tuple) for partial in partials)
        input_rep = :(first(promote($(inputs...))))  # stand-in with the right type for an input
        forward_rules = Any[rule_from_partials(input_rep, partial.args...) for partial in partials]
        reverse_rules = Any[]
        for i in 1:length(inputs)
            reverse_partials = [partial.args[i] for partial in partials]
            push!(reverse_rules, rule_from_partials(inputs[i], reverse_partials...))
        end
    else
        @assert length(inputs) == 1 && all(!Meta.isexpr(partial, :tuple) for partial in partials)
        forward_rules = Any[rule_from_partials(inputs[1], partial) for partial in partials]
        reverse_rules = Any[rule_from_partials(inputs[1], partials...)]
    end

    # First pseudo-partial is derivative WRT function itself.  Since this macro does not
    # support closures, it is just the empty NamedTuple
    forward_rules = Expr(:tuple, NO_FIELDS_RULE, forward_rules...)
    reverse_rules = Expr(:tuple, NO_FIELDS_RULE, reverse_rules...)
    return quote
        if fieldcount(typeof($f)) > 0
            throw(ArgumentError(
                "@scalar_rule cannot be used on closures/functors (such as $f)"
            ))
        end

        function ChainRulesCore.frule(::typeof($f), $(inputs...))
            $(esc(:Ω)) = $call
            $(setup_stmts...)
            return $(esc(:Ω)), $forward_rules
        end
        function ChainRulesCore.rrule(::typeof($f), $(inputs...))
            $(esc(:Ω)) = $call
            $(setup_stmts...)
            return $(esc(:Ω)), $reverse_rules
        end
    end
end

function rule_from_partials(input_arg, ∂s...)
    wirtinger_indices = findall(x -> Meta.isexpr(x, :call) && x.args[1] === :Wirtinger,  ∂s)
    ∂s = map(esc, ∂s)
    Δs = [Symbol(string(:Δ, i)) for i in 1:length(∂s)]
    Δs_tuple = Expr(:tuple, Δs...)
    if isempty(wirtinger_indices)
        ∂_mul_Δs = [:(@thunk($(∂s[i])) * $(Δs[i])) for i in 1:length(∂s)]
        return :(Rule($Δs_tuple -> +($(∂_mul_Δs...))))
    else
        ∂_mul_Δs_primal = Any[]
        ∂_mul_Δs_conjugate = Any[]
        ∂_wirtinger_defs = Any[]
        for i in 1:length(∂s)
            if i in wirtinger_indices
                Δi = Δs[i]
                ∂i = Symbol(string(:∂, i))
                push!(∂_wirtinger_defs, :($∂i = $(∂s[i])))
                ∂f∂i_mul_Δ = :(wirtinger_primal($∂i) * wirtinger_primal($Δi))
                ∂f∂ī_mul_Δ̄ = :(conj(wirtinger_conjugate($∂i)) * wirtinger_conjugate($Δi))
                ∂f̄∂i_mul_Δ = :(wirtinger_conjugate($∂i) * wirtinger_primal($Δi))
                ∂f̄∂ī_mul_Δ̄ = :(conj(wirtinger_primal($∂i)) * wirtinger_conjugate($Δi))
                push!(∂_mul_Δs_primal, :($∂f∂i_mul_Δ + $∂f∂ī_mul_Δ̄))
                push!(∂_mul_Δs_conjugate, :($∂f̄∂i_mul_Δ + $∂f̄∂ī_mul_Δ̄))
            else
                ∂_mul_Δ = :(@thunk($(∂s[i])) * $(Δs[i]))
                push!(∂_mul_Δs_primal, ∂_mul_Δ)
                push!(∂_mul_Δs_conjugate, ∂_mul_Δ)
            end
        end
        primal_rule = :(Rule($Δs_tuple -> +($(∂_mul_Δs_primal...))))
        conjugate_rule = :(Rule($Δs_tuple -> +($(∂_mul_Δs_conjugate...))))
        return quote
            $(∂_wirtinger_defs...)
            AbstractRule(typeof($input_arg), $primal_rule, $conjugate_rule)
        end
    end
end
