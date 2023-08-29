struct CompoundSpecies end
struct CompoundComponents end
struct CompoundCoefficients end

Symbolics.option_to_metadata_type(::Val{:iscompound}) = CompoundSpecies
Symbolics.option_to_metadata_type(::Val{:components}) = CompoundComponents
Symbolics.option_to_metadata_type(::Val{:coefficients}) = CompoundCoefficients

macro compound(species_expr, arr_expr...)
    # Ensure the species name is a valid expression
    if !(species_expr isa Expr && species_expr.head == :call)
        error("Invalid species name in @compound macro")
    end

    # Parse the species name to extract the species name and argument
    species_name = species_expr.args[1]
    species_arg = species_expr.args[2]

    # Construct the expressions that define the species
    species_expr = Expr(:macrocall, Symbol("@species"), LineNumberNode(0),
        Expr(:call, species_name, species_arg))

    # Construct the expression to set the iscompound metadata
    setmetadata_expr = :($(species_name) = ModelingToolkit.setmetadata($(species_name),
        Catalyst.CompoundSpecies,
        true))

    # Ensure the expressions are evaluated in the correct scope by escaping them
    escaped_species_expr = esc(species_expr)
    escaped_setmetadata_expr = esc(setmetadata_expr)

    # Construct the array from the remaining arguments
    arr = Expr(:vect, (arr_expr)...)
    coeffs = []
    species = []

    for expr in arr_expr
        if isa(expr, Expr) && expr.head == :call && expr.args[1] == :*
            push!(coeffs, expr.args[2])
            push!(species, expr.args[3])
        else
            push!(coeffs, 1)
            push!(species, expr)
        end
    end

    coeffs_expr = Expr(:vect, coeffs...)
    species_expr = Expr(:vect, species...)

    # Construct the expression to set the components metadata
    setcomponents_expr = :($(species_name) = ModelingToolkit.setmetadata($(species_name),
        Catalyst.CompoundComponents,
        $species_expr))

    # Ensure the expression is evaluated in the correct scope by escaping it
    escaped_setcomponents_expr = esc(setcomponents_expr)

    # Construct the expression to set the coefficients metadata
    setcoefficients_expr = :($(species_name) = ModelingToolkit.setmetadata($(species_name),
        Catalyst.CompoundCoefficients,
        $coeffs_expr))

    escaped_setcoefficients_expr = esc(setcoefficients_expr)

    # Return a block that contains the escaped expressions
    return Expr(:block, escaped_species_expr, escaped_setmetadata_expr,
        escaped_setcomponents_expr, escaped_setcoefficients_expr)
end

# Check if a species is a compound
iscompound(s::Num) = iscompound(MT.value(s))
function iscompound(s)
    MT.getmetadata(s, CompoundSpecies, false)
end

coefficients(s::Num) = coefficients(MT.value(s))
function coefficients(s)
    MT.getmetadata(s, CompoundCoefficients)
end

components(s::Num) = components(MT.value(s))
function components(s)
    MT.getmetadata(s, CompoundComponents)
end

component_coefficients(s::Num) = component_coefficients(MT.value(s))
function component_coefficients(s)
    return [c => co for (c, co) in zip(components(s), coefficients(s))]
end


### Balancing Code

function create_matrix(reaction::Catalyst.Reaction)
    compounds = [reaction.substrates; reaction.products]
    atoms = [] # Array to store unique atoms
    n_atoms = 0
    A = zeros(Int, 0, length(compounds))

    for (j, compound) in enumerate(compounds)
        # Check if the compound is a valid compound
        if iscompound(compound)
            # Get component coefficients of the compound
            pairs = component_coefficients(compound)
            if pairs == Nothing 
                continue
            end
        else 
            # If not a compound, assume coefficient of 1
            pairs = [(compound, 1)]
        end

        for pair in pairs
            # Extract atom and coefficient from the pair
            atom, coeff = pair
            i = findfirst(x -> isequal(x, atom), atoms)
            if i === nothing  
                # Add the atom to the atoms array if it's not already present
                push!(atoms, atom)
                n_atoms += 1
                A = [A; zeros(Int, 1, length(compounds))]
                i = n_atoms
            end
            # Adjust coefficient based on whether the compound is a product or substrate
            coeff = any(map(p -> isequal(p, compounds[j]), reaction.products)) ? -coeff : coeff
            A[i, j] = coeff
        end
    end

    return A
end

function get_stoich(reaction::Reaction)
    # Create the matrix A using create_matrix function.
    A = create_matrix(reaction)
    
    X = ModelingToolkit.nullspace(A)

    m, n = size(X)
        if n == 1
            X = abs.(vec(X))
            common_divisor = reduce(gcd, X)
            X = X ./ common_divisor

        elseif n > 1
            error("Chemical equation can be balanced in infinitely many ways")
        else
            error("Chemical equation cannot be balanced")
        end

        return X
end

function balance_reaction(reaction::Reaction)
    # Calculate the stoichiometric coefficients for the balanced reaction.
    stoichiometries = get_stoich(reaction)

    # Divide the stoichiometry vector into substrate and product stoichiometries.
    substoich = stoichiometries[1:length(reaction.substrates)]
    prodstoich = stoichiometries[(length(reaction.substrates)) + 1:end]

    # Create a new reaction with the balanced stoichiometries
    balanced_reaction = Reaction(reaction.rate, reaction.substrates, reaction.products, substoich, prodstoich)

    # Return the balanced reaction
    return balanced_reaction
end

# function backward_substitution(A::AbstractMatrix{T}, B::AbstractVector{T}) where T <: Number
#     n = length(B)
#     x = zeros(Rational{Int}, n)
#     for i in n:-1:1
#         if all(A[i, :] .== 0)
#             x[i] = 1
#         else
#             x[i] = (B[i] - A[i, i+1:n]' * x[i+1:n]) / A[i, i]
#         end
#     end
#     return x
# end

