"""
`normalisename` takes a rider's name and returns a normalised version of it.

The normalisation process involves:
    * removing accents
    * removing case
    * replacing spaces with hyphens
"""
function normalisename(ridername::String, iskey::Bool=false)
    spacechar = iskey ? "" : "-"
    newname = replace(
        Unicode.normalize(ridername, stripmark=true, stripcc=true, casefold=true),
        " " => spacechar
    )
    return newname
end

"""
`createkey` creates a unique key for each rider based on their name.
"""
function createkey(ridername::String)
    newkey = join(sort(collect(normalisename(ridername, true))))
    return newkey
end

"""
`unpipe` takes a vector of strings and replaces all instances of `|` with `-`.
"""
function unpipe(str::String)
    return replace(str, "|" => "-")
end
