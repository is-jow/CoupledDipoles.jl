function get_steady_state(problem::LinearOptics{Scalar}) # @memoize 
    @debug "start: get steady state"
    
    G  = get_interaction_matrix(problem)
    Ωₙ = apply_laser_over_atoms(problem.laser, problem.atoms)
    βₛ = (im/2)*(G \ Ωₙ)

    @debug "end  : get steady state"
    return βₛ
end
function get_steady_state(problem::NonLinearOptics{MeanField}; time_max=50)
    u0 = default_evolution_initial_condition(problem)
    tspan = (0.0, time_max)

    steady_state = time_evolution(problem, u0, tspan; save_on=false)[end]
    return steady_state
end



function time_evolution(problem::LinearOptics{T}, u₀, tspan::Tuple;  kargs...) where T <: Linear
    @debug "start: time evolution - LinearOptics"
    ### parameters == constant vector and matrices
    G = get_interaction_matrix(problem)
    Ωₙ = -0.5im*apply_laser_over_atoms(problem.laser, problem.atoms)
    parameters = view(G,:,:), view(Ωₙ,:)
    
    ### calls for solver
    problemFunction = get_evolution_function(problem)
    prob = ODEProblem(problemFunction, u₀, tspan, parameters)
    solution = DifferentialEquations.solve(prob, VCABM(); dt=1e-10, abstol=1e-10, reltol=1e-10, kargs...)
    
    @debug "end  : time evolution - LinearOptics"
    return solution
end

"""
    default_evolution_initial_condition(::Scalar) = zeros(ComplexF64, N)
"""
function default_evolution_initial_condition(problem::LinearOptics{Scalar})
    zeros(ComplexF64, problem.atoms.N) # I must use "zeros" and NOT an undef array - with trash data inside
end

get_evolution_function(problem::LinearOptics{Scalar}) = Scalar!

function Scalar!(du, u, p, t)
    G, Ωₙ = p

    du[:] = G*u + Ωₙ
    return nothing
end



# function extract_solution_from_Scalar_Problem(solution)
#     nSteps = length(solution.u)
#     time_array = [solution.t[i]  for i in 1:nSteps]
#     βₜ = [solution.u[i]  for i in 1:nSteps]
#     return time_array, βₜ
# end


# ### --------------- MEAN FIELD ---------------
function time_evolution(problem::NonLinearOptics{MeanField}, u₀, tspan::Tuple;  kargs...)
    @debug "start: time evolution - NonLinearOptics"
    G = get_interaction_matrix(problem)

    #= 
        I don't sum over diagonal elements during time evolution
     thus, to avoid an IF statement, I put a zero on diagonal 
    =#
    G[diagind(G)] .= zero(eltype(G))

    #= 
        Also, the definition for Mean Field evolution needs
     +(Γ/2), where scalar kernel return -(Γ/2).
     Just multiply by -1 fixes
    =#
    G = -G

    Ωₙ = apply_laser_over_atoms(problem.laser, problem.atoms)
    Wₙ = zeros(eltype(Ωₙ),  size(Ωₙ))
    G_βₙ = zeros(eltype(Ωₙ), size(Ωₙ))
    parameters = view(G,:,:), view(diag(G),:), view(Ωₙ,:), Wₙ, problem.laser.Δ, problem.atoms.N, G_βₙ
    
    ### calls for solver
    problemFunction = get_evolution_function(problem)
    prob = ODEProblem(problemFunction, u₀, tspan, parameters)
    solution = DifferentialEquations.solve(prob, VCABM(); dt=1e-10, abstol=1e-10, reltol=1e-10, kargs...)

    @debug "end  : time evolution - NonLinearOptics"
    return solution
end
get_evolution_function(problem::NonLinearOptics{MeanField}) = MeanField!

"""
    default_evolution_initial_condition(NonLinearOptics{MeanField})
β₀ = zeros(ComplexF64, atoms.N)
z₀ = 2β₀.*conj.(β₀) .- 1
"""
function default_evolution_initial_condition(problem::NonLinearOptics{MeanField})
    β₀ = zeros(ComplexF64, problem.atoms.N)
    z₀ = 2β₀.*conj.(β₀) .- 1
    u₀ = vcat(β₀, z₀)
    return u₀
end
function MeanField!(du, u, p, t)
    # parameters
    G, diagG, Ωₙ, Wₙ, Δ, N, G_βₙ = p
    
    βₙ = @view u[1:N]
    zₙ = @view u[N+1:end]
    
    #= Code below is equivalento to =#
    # Wₙ[:] .= Ωₙ/2 - im*(G*βₙ - diagG.*βₙ) # don't forget the element wise multiplication of "diagG.*βₙ"
    # @. du[1:N] = (im*Δ - Γ/2)*βₙ + im*Wₙ*zₙ
    # @. du[N+1:end] = -Γ*(1 + zₙ) - 4*imag(βₙ*conj(Wₙ))
    
    BLAS.gemv!('N', ComplexF64(1.0), G, βₙ, ComplexF64(0.0), G_βₙ) # == G_βₙ = G*βₙ
    @simd for i ∈ eachindex(Wₙ)
        @inbounds Wₙ[i] = Ωₙ[i]/2 - im*(G_βₙ[i] - diagG[i]*βₙ[i])
    end
    @simd for i ∈ eachindex(βₙ)
        @inbounds du[i] = (im*Δ - Γ/2)*βₙ[i] + im*Wₙ[i]*zₙ[i]
    end
    @simd for i ∈ eachindex(zₙ)
        @inbounds du[i+N] = -Γ*(1 + zₙ[i]) - 4*imag(βₙ[i]*conj(Wₙ[i]))
    end

    return nothing
end
# function extract_solution_from_MeanField_Problem(solution)
#     nTimeSteps = length(solution.u)
#     time_array = [solution.t[i]  for i in 1:nTimeSteps   ]
    
#     N = length(solution.u[1])÷2
#     βₜ = [solution.u[i][1:N]  for i in 1:nTimeSteps   ]
#     zₜ = [solution.u[i][(N+1):end]  for i in 1:nTimeSteps   ]
#     return time_array, βₜ, zₜ
# end