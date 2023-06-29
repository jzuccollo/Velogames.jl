"""
`normalise_name` takes a rider's name and returns a normalised version of it.

The normalisation process involves:
    * removing accents
    * removing case
    * replacing spaces with hyphens
"""
function normalise_name(rider_name::String)
    new_name = replace(
        Unicode.normalize(rider_name, stripmark=true, stripcc=true, casefold=true),
        " " => "-"
    )
    return new_name
end

"""
`create_key` creates a unique key for each rider based on their name.
"""
function create_key(rider_name::String)
    s = replace(rider_name, r"[^a-zA-Z0-9_]" => "")
    newkey = join(
        sort(
            collect(
                Unicode.normalize(s, stripmark=true, stripcc=true, casefold=true),
            ),
        ),
    )
    return newkey
end