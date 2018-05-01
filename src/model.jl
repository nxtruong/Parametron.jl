mutable struct Constraint{S<:MOI.AbstractSet}
    fun::DataPair{AffineFunction, MOI.VectorAffineFunction{Float64}}
    set::S
    modelindex::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64}, S}
    optimizerindex::MOI.ConstraintIndex{MOI.VectorAffineFunction{Float64}, S}
    Constraint(f::AffineFunction, set::S) where {S<:MOI.AbstractSet} = new{S}(DataPair(f, MOI.VectorAffineFunction(f)), set)
end

mutable struct Model{O<:MOI.AbstractOptimizer}
    backend::SimpleQPMOIModel{Float64}
    optimizer::O
    initialized::Bool
    objective::DataPair{QuadraticFunction, MOI.ScalarQuadraticFunction{Float64}}
    nonnegconstraints::Vector{Constraint{MOI.Nonnegatives}}
    nonposconstraints::Vector{Constraint{MOI.Nonpositives}}
    zeroconstraints::Vector{Constraint{MOI.Zeros}}
    user_var_to_optimizer::Vector{MOI.VariableIndex}

    function Model(optimizer::O) where O
        VI = MOI.VariableIndex
        backend = SimpleQPMOIModel{Float64}()
        initialized = false
        objective = DataPair(QuadraticFunction(), MOI.ScalarQuadraticFunction(VI[], Float64[], VI[], VI[], Float64[], 0.0))
        nonnegconstraints = Constraint{MOI.Nonnegatives}[]
        nonposconstraints = Constraint{MOI.Nonpositives}[]
        zeroconstraints = Constraint{MOI.Zeros}[]
        user_var_to_optimizer = Vector{MOI.VariableIndex}()
        new{O}(backend, optimizer, initialized, objective, nonnegconstraints, nonposconstraints, zeroconstraints, user_var_to_optimizer)
    end
end

function Variable(m::Model)
    m.initialized && error()
    index = MOI.addvariable!(m.backend)
    Variable(index)
end

function setobjective!(m::Model, sense::Senses.Sense, f)
    m.initialized && error()
    MOI.set!(m.backend, MOI.ObjectiveSense(), MOI.OptimizationSense(sense)) # TODO: consider putting in a DataPair as well
    m.objective.native = convert(QuadraticFunction, f)
    m.objective.moi = MOI.ScalarQuadraticFunction(m.objective.native)
    # update!(m.objective)
    MOI.set!(m.backend, MOI.ObjectiveFunction{MOI.ScalarQuadraticFunction{Float64}}(), m.objective.moi)
    nothing
end

Base.push!(m::Model, c::Constraint{MOI.Nonnegatives}) = push!(m.nonnegconstraints, c)
Base.push!(m::Model, c::Constraint{MOI.Nonpositives}) = push!(m.nonposconstraints, c)
Base.push!(m::Model, c::Constraint{MOI.Zeros}) = push!(m.zeroconstraints, c)

function addconstraint!(m::Model, f, set::MOI.AbstractVectorSet)
    m.initialized && error()
    f_affine = convert(AffineFunction, f)
    constraint = Constraint(f_affine, set)
    constraint.modelindex = MOI.addconstraint!(m.backend, MOI.VectorAffineFunction(f_affine), set)
    push!(m, constraint)
    nothing
end

add_nonnegative_constraint!(m::Model, f) = addconstraint!(m, f, MOI.Nonnegatives(outputdim(f)))
add_nonpositive_constraint!(m::Model, f) = addconstraint!(m, f, MOI.Nonpositives(outputdim(f)))
add_zero_constraint!(m::Model, f) = addconstraint!(m, f, MOI.Zeros(outputdim(f)))

function mapindices(m::Model, idxmap)
    for c in m.nonnegconstraints
        c.optimizerindex = idxmap[c.modelindex]
    end
    for c in m.nonposconstraints
        c.optimizerindex = idxmap[c.modelindex]
    end
    for c in m.zeroconstraints
        c.optimizerindex = idxmap[c.modelindex]
    end
    backend_var_indices = MOI.get(m.backend, MOI.ListOfVariableIndices())
    resize!(m.user_var_to_optimizer, length(backend_var_indices))
    for index in backend_var_indices
        m.user_var_to_optimizer[index.value] = idxmap[index]
    end
end

@noinline function initialize!(m::Model)
    result = MOI.copy!(m.optimizer, m.backend)
    if result.status == MOI.CopySuccess
        mapindices(m, result.indexmap)
    else
        error("Copy failed with status ", result.status, ". Message: ", result.message)
    end
    m.initialized = true
    nothing
end

function updateobjective!(m::Model)
    update!(m.objective, m.user_var_to_optimizer)
    MOI.set!(m.optimizer, MOI.ObjectiveFunction{MOI.ScalarQuadraticFunction{Float64}}(), m.objective.moi)
end

function updateconstraint!(m::Model, constraint::Constraint)
    update!(constraint.fun, m.user_var_to_optimizer)
    MOI.modifyconstraint!(m.optimizer, constraint.optimizerindex, constraint.fun.moi)
end

function update!(m::Model)
    updateobjective!(m)
    for c in m.nonnegconstraints
        updateconstraint!(m, c)
    end
    for c in m.nonposconstraints
        updateconstraint!(m, c)
    end
    for c in m.zeroconstraints
        updateconstraint!(m, c)
    end
    nothing
end

function solve!(m::Model)
    if !m.initialized
        initialize!(m)
        m.initialized = true
    end
    update!(m)
    MOI.optimize!(m.optimizer)
    nothing
end

function value(m::Model, x::Variable)
    MOI.get(m.optimizer, MOI.VariablePrimal(), m.user_var_to_optimizer[x.index])
end

function objectivevalue(m::Model)
    MOI.get(m.optimizer, MOI.ObjectiveValue())
end
