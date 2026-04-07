# ---------------------------------------------------------------------------
# Qualitative intelligence extraction
# ---------------------------------------------------------------------------
# Extract expert assessments from podcasts/articles via LLM, convert to
# structured signals for the Bayesian prediction pipeline.

# Categorical adjustment scale (z-score units)
const QUALITATIVE_ADJUSTMENTS = Dict(
    "strong_positive" => 1.0,
    "moderate_positive" => 0.5,
    "slight_positive" => 0.25,
    "neutral" => 0.0,
    "slight_negative" => -0.25,
    "moderate_negative" => -0.5,
    "strong_negative" => -1.0,
)

# Confidence level mapping
const QUALITATIVE_CONFIDENCES = Dict("high" => 0.8, "medium" => 0.5, "low" => 0.3)

const ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
const ANTHROPIC_MODEL = "claude-sonnet-4-6"


"""
    fetch_transcript(youtube_url) -> String

Download and clean YouTube auto-captions via yt-dlp. Returns the transcript
as a single string with timestamps and duplicates removed.

Requires yt-dlp to be installed (`brew install yt-dlp`).
"""
function fetch_transcript(youtube_url::String)
    mktempdir() do tmpdir
        output_template = joinpath(tmpdir, "transcript")
        try
            run(`yt-dlp --write-auto-sub --sub-lang en --skip-download
                 --sub-format vtt -o $output_template $youtube_url`)
        catch e
            error("yt-dlp failed — ensure it is installed (`brew install yt-dlp`): $e")
        end

        vtt_files = filter(f -> endswith(f, ".vtt"), readdir(tmpdir; join = true))
        if isempty(vtt_files)
            error("No subtitle file found — video may not have auto-captions")
        end

        raw = read(first(vtt_files), String)
        lines = String[]
        prev = ""
        for line in split(raw, "\n")
            stripped = strip(line)
            startswith(stripped, "WEBVTT") && continue
            startswith(stripped, "Kind:") && continue
            startswith(stripped, "Language:") && continue
            occursin(r"^\d{2}:\d{2}:", stripped) && continue
            occursin(r"-->", stripped) && continue
            isempty(stripped) && continue
            cleaned = replace(stripped, r"<[^>]+>" => "")
            if cleaned != prev && !isempty(cleaned)
                push!(lines, cleaned)
                prev = cleaned
            end
        end
        return join(lines, " ")
    end
end


"""
    build_qualitative_prompt(riders, race_name, race_date; transcript="") -> String

Generate a structured prompt for extracting rider-level intelligence from a
transcript or from general knowledge. The prompt asks for categorical
assessments (strong_positive to strong_negative) with confidence levels.
"""
function build_qualitative_prompt(
    riders::Vector{String},
    race_name::String,
    race_date::String;
    transcript::String = "",
)
    rider_list = join(["- $r" for r in riders], "\n")

    source_instruction = if isempty(transcript)
        "Based on your knowledge of recent cycling news, form, and expert commentary:"
    else
        """Based on the following transcript from a cycling podcast/preview, extract intelligence about rider form, motivation, injuries, team tactics, and course suitability.

<transcript>
$transcript
</transcript>

Using the transcript above and your cycling knowledge:"""
    end

    return """You are a professional cycling analyst extracting race intelligence from preview articles and podcasts. $source_instruction

Race: $race_name ($race_date)

For each rider in the startlist below who is mentioned in the source text, provide a JSON assessment. The source may be in any language — match riders by name regardless of language.

Important guidelines:
- SKIP riders mentioned as absent, injured, or not starting — they are not relevant.
- Base your assessment strictly on what the source says. If the source rates a rider as a top favourite, that is a strong positive signal. If a rider is listed among outsiders, that is a slight positive. Do not second-guess the source's assessment with your own interpretation.
- If the source provides a structured ranking (e.g. star ratings, tiers), use that as the primary basis for your category assignment.
- Include every rider discussed who IS racing, even if the intelligence is minor.

Riders in the startlist:
$rider_list

For each mentioned rider who is starting the race, provide:
- "rider": exact name from the startlist above (match by surname if needed)
- "category": one of: strong_positive, moderate_positive, slight_positive, neutral, slight_negative, moderate_negative, strong_negative
- "confidence": one of: high (clear specific intelligence), medium (reasonable impression), low (speculative)
- "reasoning": one sentence explaining the assessment

Respond with a JSON array only, no other text. Example:
```json
[
  {"rider": "Mathieu van der Poel", "category": "moderate_positive", "confidence": "high", "reasoning": "Rated as top favourite (4 stars), won recent Kuurne and looks in top form."},
  {"rider": "Wout van Aert", "category": "slight_negative", "confidence": "medium", "reasoning": "Listed among outsiders despite being a former winner, suggesting uncertain form."}
]
```"""
end


"""
    extract_qualitative_claude(prompt) -> String

Call the Anthropic Messages API with the given prompt and return the raw
text response. Reads ANTHROPIC_API_KEY from environment.
"""
function extract_qualitative_claude(prompt::String)
    api_key = get(ENV, "ANTHROPIC_API_KEY", "")
    if isempty(api_key)
        error(
            "ANTHROPIC_API_KEY not set. Get one from console.anthropic.com " *
            "and add to .envrc",
        )
    end

    body = JSON3.write(
        Dict(
            "model" => ANTHROPIC_MODEL,
            "max_tokens" => 4096,
            "messages" => [Dict("role" => "user", "content" => prompt)],
        ),
    )

    headers = [
        "x-api-key" => api_key,
        "anthropic-version" => "2023-06-01",
        "content-type" => "application/json",
    ]

    response = HTTP.post(ANTHROPIC_API_URL, headers, body)
    result = JSON3.read(String(response.body))

    content_blocks = result.content
    if isempty(content_blocks)
        error("Empty response from Claude API")
    end
    return String(first(content_blocks).text)
end


"""
    parse_qualitative_response(json_text) -> DataFrame

Parse a JSON array of rider assessments (from Claude API or a saved file)
into the standard qualitative signal DataFrame with columns:
rider, adjustment, confidence, reasoning, riderkey.
"""
function parse_qualitative_response(json_text::String)
    cleaned = replace(json_text, r"```json\s*" => "")
    cleaned = replace(cleaned, r"```\s*$" => "")
    cleaned = strip(cleaned)

    entries = JSON3.read(cleaned)

    riders_out = String[]
    adjustments_out = Float64[]
    confidences_out = Float64[]
    reasonings_out = String[]
    keys_out = String[]

    for entry in entries
        name = String(get(entry, :rider, ""))
        cat = String(get(entry, :category, "neutral"))
        conf_str = String(get(entry, :confidence, "low"))
        reasoning = String(get(entry, :reasoning, ""))

        isempty(name) && continue

        adj = get(QUALITATIVE_ADJUSTMENTS, cat, 0.0)
        conf = get(QUALITATIVE_CONFIDENCES, conf_str, 0.3)

        push!(riders_out, name)
        push!(adjustments_out, adj)
        push!(confidences_out, conf)
        push!(reasonings_out, reasoning)
        push!(keys_out, createkey(name))
    end

    return DataFrame(
        rider = riders_out,
        adjustment = adjustments_out,
        confidence = confidences_out,
        reasoning = reasonings_out,
        riderkey = keys_out,
    )
end


"""
    fetch_article_text(url) -> String

Fetch a web article and extract its main text content. Strips navigation,
scripts, styles, and other boilerplate, returning the article body as plain text.
"""
function fetch_article_text(url::String)
    response = HTTP.get(url, ["User-Agent" => "Mozilla/5.0 (compatible; VelogamesBot/1.0)"])
    page = Gumbo.parsehtml(String(response.body))

    # Collect all text from each block element, filtering out short blocks (nav fragments)
    # but preserving short inline nodes (rider names in <a>/<strong> tags)
    block_tags = Set(["p", "div", "article", "section", "li", "h1", "h2", "h3", "h4", "h5", "h6", "td", "th", "figcaption", "blockquote"])
    skip_tags = Set(["script", "style", "nav", "footer", "header", "aside"])
    blocks = String[]

    function collect_inline_text(node)
        if isa(node, Gumbo.HTMLText)
            return strip(node.text)
        elseif isa(node, Gumbo.HTMLElement)
            tag = lowercase(string(Gumbo.tag(node)))
            tag in skip_tags && return ""
            parts = [collect_inline_text(child) for child in Gumbo.children(node)]
            return join(filter(!isempty, parts), " ")
        end
        return ""
    end

    function collect_blocks(node)
        if isa(node, Gumbo.HTMLElement)
            tag = lowercase(string(Gumbo.tag(node)))
            tag in skip_tags && return
            if tag in block_tags
                text = collect_inline_text(node)
                length(text) > 20 && push!(blocks, text)
            else
                for child in Gumbo.children(node)
                    collect_blocks(child)
                end
            end
        end
    end
    collect_blocks(page.root)

    return join(blocks, "\n\n")
end


"""
    get_qualitative_article(article_url, riders, race_name, race_date) -> DataFrame

Full automated pipeline: fetch article text → extract intelligence
via Claude API → parse into DataFrame.
"""
function get_qualitative_article(
    article_url::String,
    riders::Vector{String},
    race_name::String,
    race_date::String,
)
    @info "Fetching article from $article_url..."
    text = fetch_article_text(article_url)
    @info "Got $(length(text)) characters of article text"

    prompt = build_qualitative_prompt(riders, race_name, race_date; transcript = text)
    @info "Calling Claude API for qualitative extraction..."
    response_text = extract_qualitative_claude(prompt)
    @info "Parsing qualitative response..."
    return parse_qualitative_response(response_text)
end


"""
    get_qualitative_auto(youtube_url, riders, race_name, race_date) -> DataFrame

Full automated pipeline: fetch YouTube transcript → extract intelligence
via Claude API → parse into DataFrame.
"""
function get_qualitative_auto(
    youtube_url::String,
    riders::Vector{String},
    race_name::String,
    race_date::String,
)
    @info "Fetching transcript from $youtube_url..."
    transcript = fetch_transcript(youtube_url)
    @info "Got $(length(transcript)) characters of transcript"

    prompt = build_qualitative_prompt(riders, race_name, race_date; transcript = transcript)
    @info "Calling Claude API for qualitative extraction..."
    response_text = extract_qualitative_claude(prompt)
    @info "Parsing qualitative response..."
    return parse_qualitative_response(response_text)
end


"""
    load_qualitative_file(filepath) -> DataFrame

Load a manually saved JSON response file and parse it into the standard
qualitative signal DataFrame.
"""
function load_qualitative_file(filepath::String)
    json_text = read(filepath, String)
    return parse_qualitative_response(json_text)
end
