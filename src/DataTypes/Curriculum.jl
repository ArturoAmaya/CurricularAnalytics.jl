##############################################################
# Curriculum data type
# The required curriculum associated with a degree program
"""
The `Curriculum` data type is used to represent the collection of courses that must be
be completed in order to earn a particualr degree. Thus, we use the terms *curriculum* and
*degree program* synonymously. To instantiate a `Curriculum` use:

    Curriculum(name, courses; <keyword arguments>)

# Arguments
Required:
- `name::AbstractString` : the name of the curriculum.
- `courses::Array{Course}` : the collection of required courses that comprise the curriculum.
Keyword:
- `degree_type::AbstractString` : the type of degree, e.g. BA, BBA, BSc, BEng, etc.
- `institution:AbstractString` : the name of the institution offering the curriculum.
- `system_type::System` : the type of system the institution uses, allowable 
    types: `semester` (default), `quarter`.
- `CIP::AbstractString` : the Classification of Instructional Programs (CIP) code for the 
    curriculum.  See: `https://nces.ed.gov/ipeds/cipcode`

# Examples:
```julia-repl
julia> Curriculum("Biology", courses, institution="South Harmon Tech", degree_type=AS, CIP="26.0101")
```
"""
mutable struct Curriculum
    id::Int                             # Unique curriculum ID
    name::AbstractString                # Name of the curriculum (can be used as an identifier)
    institution::AbstractString         # Institution offering the curriculum
    degree_type::AbstractString                 # Type of degree_type
    system_type::System                 # Semester or quarter system
    CIP::AbstractString                 # CIP code associated with the curriculum
    courses::Array{AbstractCourse}              # Array of required courses in curriculum
    num_courses::Int                    # Number of required courses in curriculum
    credit_hours::Real                  # Total number of credit hours in required curriculum
    graph::SimpleWeightedDiGraph{Int}           # Directed graph representation of pre-/co-requisite structure
    # of the curriculum, note: this is a course graph
    learning_outcomes::Array{LearningOutcome}  # A list of learning outcomes associated with the curriculum
    learning_outcome_graph::SimpleDiGraph{Int}        # Directed graph representatin of pre-/co-requisite structure of learning
    # outcomes in the curriculum
    course_learning_outcome_graph::MetaDiGraph{Int}  # Directed Int64 metagraph with Float64 weights defined by :weight (default weight 1.0) 
    # This is a course and learning outcome graph                                             
    metrics::Dict{String,Any}          # Curriculum-related metrics
    metadata::Dict{String,Any}         # Curriculum-related metadata

    # Constructor
    function Curriculum(name::AbstractString, courses::Array{AbstractCourse}; learning_outcomes::Array{LearningOutcome}=Array{LearningOutcome,1}(),
        degree_type::AbstractString="BS", system_type::System=semester, institution::AbstractString="", CIP::AbstractString="",
        id::Int=0, sortby_ID::Bool=true, edge_weights::Array{Int64}=Array{Int64,1}())
        this = new()
        this.name = name
        this.degree_type = degree_type
        this.system_type = system_type
        this.institution = institution
        if id == 0
            this.id = mod(hash(this.name * this.institution * string(this.degree_type)), UInt32)
        else
            this.id = id
        end
        this.CIP = CIP
        if sortby_ID
            this.courses = sort(collect(courses), by=c -> c.id)
        else
            this.courses = courses
        end
        this.num_courses = length(this.courses)
        this.credit_hours = total_credits(this)

        this.graph = SimpleWeightedDiGraph() # used to include {Int}
        create_graph!(this)
        this.metrics = Dict{String,Any}()
        this.metadata = Dict{String,Any}()
        this.learning_outcomes = learning_outcomes
        this.learning_outcome_graph = SimpleDiGraph{Int}()
        create_learning_outcome_graph!(this)
        this.course_learning_outcome_graph = MetaDiGraph()
        create_course_learning_outcome_graph!(this)
        errors = IOBuffer()
        if !(isvalid_curriculum(this, errors))
            printstyled("WARNING: Curriculum was created, but is invalid due to requisite cycle(s):", color=:yellow)
            println(String(take!(errors)))
        end
        return this
    end

    function Curriculum(name::AbstractString, courses::Array{Course}; learning_outcomes::Array{LearningOutcome}=Array{LearningOutcome,1}(),
        degree_type::AbstractString="BS", system_type::System=semester, institution::AbstractString="", CIP::AbstractString="",
        id::Int=0, sortby_ID::Bool=true)
        Curriculum(name, convert(Array{AbstractCourse}, courses), learning_outcomes=learning_outcomes, degree_type=degree_type,
            system_type=system_type, institution=institution, CIP=CIP, id=id, sortby_ID=sortby_ID)
    end
end

# TODO: update a curriculum graph if requisites have been added/removed or courses have been added/removed
#function update_curriculum(curriculum::Curriculum, courses::Array{Course}=())
#    # if courses array is empty, no new courses were added
#end

# Converts course ids, from those used in CSV file format, to the standard hashed id used by the data structures in the toolbox
function convert_ids(curriculum::Curriculum)
    for c1 in curriculum.courses
        old_id = c1.id
        c1.id = mod(hash(c1.name * c1.prefix * c1.num * c1.institution), UInt32)
        if old_id != c1.id
            for c2 in curriculum.courses
                if old_id in keys(c2.requisites)
                    add_requisite!(c1, c2, c2.requisites[old_id])
                    delete!(c2.requisites, old_id)
                end
            end
        end
    end
    return curriculum
end

# Map course IDs to vertex IDs in an underlying curriculum graph.
function map_vertex_ids(curriculum::Curriculum)
    mapped_ids = Dict{Int,Int}()
    for c in curriculum.courses
        mapped_ids[c.id] = c.vertex_id[curriculum.id]
    end
    return mapped_ids
end

# Map lo IDs to vertex IDs in an underlying curriculum graph.
function map_lo_vertex_ids(curriculum::Curriculum)
    mapped_ids = Dict{Int,Int}()
    for lo in curriculum.learning_outcomes
        mapped_ids[lo.id] = lo.vertex_id[curriculum.id]
    end
    return mapped_ids
end

# Compute the hash value used to create the id for a course, and return the course if it exists in the curriculum supplied as input
function course(curric::Curriculum, prefix::AbstractString, num::AbstractString, name::AbstractString, institution::AbstractString)
    hash_val = mod(hash(name * prefix * num * institution), UInt32)
    if hash_val in collect(c.id for c in curric.courses)
        return curric.courses[findfirst(x -> x.id == hash_val, curric.courses)]
    else
        error("Course: $prefix $num: $name at $institution does not exist in curriculum: $(curric.name)")
    end
end

# Return the course associated with a course id in a curriculum
function course_from_id(curriculum::Curriculum, id::Int)
    for c in curriculum.courses
        if c.id == id
            return c
        end
    end
end

# Return the lo associated with a lo id in a curriculum
function lo_from_id(curriculum::Curriculum, id::Int)
    for lo in curriculum.learning_outcomes
        if lo.id == id
            return lo
        end
    end
end

# Return the course associated with a vertex id in a curriculum graph
function course_from_vertex(curriculum::Curriculum, vertex::Int)
    c = curriculum.courses[vertex]
end

# The total number of credit hours in a curriculum
function total_credits(curriculum::Curriculum)
    total_credits = 0
    for c in curriculum.courses
        total_credits += c.credit_hours
    end
    return total_credits
end

#"""
#    create_graph!(c::Curriculum)
#
#Create a curriculum directed graph from a curriculum specification. The graph is stored as a 
#LightGraph.jl implemenation within the Curriculum data object.
#"""
function create_graph!(curriculum::Curriculum)
    for (i, c) in enumerate(curriculum.courses)
        if add_vertex!(curriculum.graph)
            c.vertex_id[curriculum.id] = i    # The vertex id of a course w/in the curriculum
        # Graphs.jl orders graph vertices sequentially
        # TODO: make sure course is not alerady in the curriculum   
        else
            error("vertex could not be created")
        end
    end
    mapped_vertex_ids = map_vertex_ids(curriculum)
    for c in curriculum.courses
        for r in collect(keys(c.requisites))
            if add_edge!(curriculum.graph, mapped_vertex_ids[r], c.vertex_id[curriculum.id], course_from_id(curriculum, r).passrate) # edge is r to c. Need r's passrate (or fail rate)
            else
                s = course_from_id(curriculum, r)
                error("edge could not be created: ($(s.name), $(c.name))")
            end
        end
    end
end

#"""
#    create_course_learning_outcome_graph!(c::Curriculum)
#
#Create a curriculum directed graph from a curriculum specification. This graph graph contains courses and learning outcomes
# of the curriculum. The graph is stored as a LightGraph.jl implemenation within the Curriculum data object.


#"""
function create_course_learning_outcome_graph!(curriculum::Curriculum)
    len_courses = size(curriculum.courses)[1]
    len_learning_outcomes = size(curriculum.learning_outcomes)[1]

    for (i, c) in enumerate(curriculum.courses)
        if add_vertex!(curriculum.course_learning_outcome_graph)
            c.vertex_id[curriculum.id] = i    # The vertex id of a course w/in the curriculum
        # Graphs.jl orders graph vertices sequentially
        # TODO: make sure course is not alerady in the curriculum   
        else
            error("vertex could not be created")
        end

    end

    for (j, lo) in enumerate(curriculum.learning_outcomes)
        if add_vertex!(curriculum.course_learning_outcome_graph)
            lo.vertex_id[curriculum.id] = len_courses + j   # The vertex id of a learning outcome w/in the curriculum
        # Graphs.jl orders graph vertices sequentially
        # TODO: make sure course is not alerady in the curriculum   
        else
            error("vertex could not be created")
        end
    end

    mapped_vertex_ids = map_vertex_ids(curriculum)
    mapped_lo_vertex_ids = map_lo_vertex_ids(curriculum)


    # Add edges among courses
    for c in curriculum.courses
        for r in collect(keys(c.requisites))
            if add_edge!(curriculum.course_learning_outcome_graph, mapped_vertex_ids[r], c.vertex_id[curriculum.id])
                set_prop!(curriculum.course_learning_outcome_graph, Edge(mapped_vertex_ids[r], c.vertex_id[curriculum.id]), :c_to_c, c.requisites[r])

            else
                s = course_from_id(curriculum, r)
                error("edge could not be created: ($(s.name), $(c.name))")
            end
        end
    end

    # Add edges among learning_outcomes
    for lo in curriculum.learning_outcomes
        for r in collect(keys(lo.requisites))
            if add_edge!(curriculum.course_learning_outcome_graph, mapped_lo_vertex_ids[r], lo.vertex_id[curriculum.id])
                set_prop!(curriculum.course_learning_outcome_graph, Edge(mapped_lo_vertex_ids[r], lo.vertex_id[curriculum.id]), :lo_to_lo, pre)
            else
                s = lo_from_id(curriculum, r)
                error("edge could not be created: ($(s.name), $(c.name))")
            end
        end
    end

    # Add edges between each pair of a course and a learning outcome
    for c in curriculum.courses
        for lo in c.learning_outcomes
            if add_edge!(curriculum.course_learning_outcome_graph, mapped_lo_vertex_ids[lo.id], c.vertex_id[curriculum.id])
                set_prop!(curriculum.course_learning_outcome_graph, Edge(mapped_lo_vertex_ids[lo.id], c.vertex_id[curriculum.id]), :lo_to_c, belong_to)
            else
                s = lo_from_id(curriculum, lo.id)
                error("edge could not be created: ($(s.name), $(c.name))")
            end
        end
    end
end



#"""
#    create_learning_outcome_graph!(c::Curriculum)
#
#Create a curriculum directed graph from a curriculum specification. The graph is stored as a 
#LightGraph.jl implemenation within the Curriculum data object.
#"""
function create_learning_outcome_graph!(curriculum::Curriculum)
    for (i, lo) in enumerate(curriculum.learning_outcomes)
        if add_vertex!(curriculum.learning_outcome_graph)
            lo.vertex_id[curriculum.id] = i   # The vertex id of a course w/in the curriculum
        # Graphs.jl orders graph vertices sequentially
        # TODO: make sure course is not alerady in the curriculum   
        else
            error("vertex could not be created")
        end
    end
    mapped_vertex_ids = map_lo_vertex_ids(curriculum)
    for lo in curriculum.learning_outcomes
        for r in collect(keys(lo.requisites))
            if add_edge!(curriculum.learning_outcome_graph, mapped_vertex_ids[r], lo.vertex_id[curriculum.id])
            else
                s = lo_from_id(curriculum, r)
                error("edge could not be created: ($(s.name), $(c.name))")
            end
        end
    end
end

# find requisite type from vertex ids in a curriculum graph
function requisite_type(curriculum::Curriculum, src_course_id::Int, dst_course_id::Int)
    src = 0
    dst = 0
    for c in curriculum.courses
        if c.vertex_id[curriculum.id] == src_course_id
            src = c
        elseif c.vertex_id[curriculum.id] == dst_course_id
            dst = c
        end
    end
    if ((src == 0 || dst == 0) || !haskey(dst.requisites, src.id))
        error("edge ($src_course_id, $dst_course_id) does not exist in curriculum graph")
    else
        return dst.requisites[src.id]
    end
end