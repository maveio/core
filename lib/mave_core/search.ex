defmodule MaveCore.Search do
  @moduledoc """
  Content search: find videos by what is visible on screen and what is said,
  and the moments where that happens.

  A space opts in under Settings → Features. New runs then store searchable
  moments for the processed video version (see `MaveCore.Search.Document` and
  the `search.index_video` flow step). Searching reads only the current version
  of videos in the given space, optionally limited to one collection and the
  collections nested in it. See `docs/video_search.md`.
  """

  import Ecto.Query, warn: false

  alias MaveCore.Assets.{Asset, Video}
  alias MaveCore.Collections.{Collection, CollectionEmbed}
  alias MaveCore.Embeds.Embed
  alias MaveCore.Repo
  alias MaveCore.Search.Moment
  alias MaveCore.Spaces
  alias MaveCore.Spaces.Space

  @sources Moment.sources()
  @default_limit 10
  @max_limit 50
  @default_moments_per_video 3
  @max_moments_per_video 10
  @max_terms 8
  @max_term_length 40
  @min_query_length 2
  # Moments closer together than this show the same part of the video.
  @distinct_moment_ms 5_000
  @snippet_length 150
  @snippet_lead 40
  @insert_batch 500

  @type snippet :: [{String.t(), boolean()}]
  @type moment :: %{
          source: String.t(),
          start: float(),
          end: float(),
          text: String.t(),
          snippet: snippet()
        }
  @type result :: %{
          embed: Embed.t(),
          score: float(),
          matched_on: [String.t()],
          moments: [moment()]
        }

  ## Requesting an index

  @doc """
  The `search` run input for a new flow run in `space`, or `nil` when the space
  does not index its videos.
  """
  def run_input(%Space{} = space) do
    if Spaces.video_search_active?(space), do: %{"sources" => @sources}
  end

  def run_input(_space), do: nil

  @doc "Sources a run asks to index: any of `visual` and `transcript`."
  def requested_sources(%{"search" => %{"sources" => sources}}) when is_list(sources),
    do: Enum.filter(@sources, &(&1 in sources))

  def requested_sources(_run_input), do: []

  def requested?(run_input, source), do: source in requested_sources(run_input)

  @doc "Object key of the private moments document of a video version."
  def document_key(embed_hash, version),
    do: "#{MaveCore.AudioDescription.version_prefix(embed_hash, version)}/search/moments.json"

  ## Indexing

  @doc """
  Replaces the searchable moments of one video version. Moments have `source`,
  `start`/`end` in seconds and `text`.
  """
  @spec index_video(Video.t(), String.t(), [map()], String.t() | nil) :: {:ok, non_neg_integer()}
  def index_video(%Video{id: video_id}, space_id, moments, language \\ nil)
      when is_binary(space_id) and is_list(moments) do
    rows =
      Enum.flat_map(moments, fn moment ->
        search_text = moment.text |> terms(:all) |> Enum.join(" ")

        if moment.source in @sources and search_text != "",
          do: [{moment.source, ms(moment.start), ms(moment.end), moment.text, search_text}],
          else: []
      end)

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from(m in Moment, where: m.video_id == ^video_id))

        rows
        |> Enum.chunk_every(@insert_batch)
        |> Enum.each(&insert_rows(&1, space_id, video_id, language))
      end)

    {:ok, length(rows)}
  end

  @doc "Number of indexed moments of a video version."
  def moment_count(%Video{id: video_id}),
    do: Repo.aggregate(from(m in Moment, where: m.video_id == ^video_id), :count, :id)

  # The vector is built from text normalized the same way as queries, so a
  # search term always meets the same tokens it was indexed as.
  defp insert_rows(rows, space_id, video_id, language) do
    {sources, starts, ends, texts, search_texts} =
      Enum.reduce(rows, {[], [], [], [], []}, fn {source, start, stop, text, search_text},
                                                 {a, b, c, d, e} ->
        {[source | a], [start | b], [stop | c], [text | d], [search_text | e]}
      end)

    Repo.query!(
      """
      INSERT INTO video_search_moments
        (id, space_id, video_id, source, start_ms, end_ms, text, language, search_vector, inserted_at)
      SELECT gen_random_uuid(), $1, $2, row.source, row.start_ms, row.end_ms, row.text, $3,
             to_tsvector('simple', row.search_text), now()
      FROM unnest($4::text[], $5::int[], $6::int[], $7::text[], $8::text[])
        AS row(source, start_ms, end_ms, text, search_text)
      """,
      [
        MaveCore.LegacyShortUUID.dump!(space_id),
        MaveCore.LegacyShortUUID.dump!(video_id),
        language,
        sources,
        starts,
        ends,
        texts,
        search_texts
      ]
    )
  end

  defp ms(seconds) when is_number(seconds), do: max(round(seconds * 1000), 0)

  ## Searching

  @doc """
  Videos of `space` matching `query`, best first, each with the moments where
  the match occurs.

  Every word must occur in one moment (or in the title); the last word may be
  unfinished, so results appear while typing. Options:

    * `:collection` - a collection `Embed`; only videos in it or in collections
      nested inside it are returned
    * `:archived` - search archived instead of active videos (default `false`)
    * `:limit` - number of videos (default #{@default_limit}, at most #{@max_limit})
    * `:moments_per_video` - default #{@default_moments_per_video}
  """
  @spec search(Space.t(), String.t(), keyword()) :: [result()]
  def search(%Space{} = space, query, opts \\ []) when is_binary(query) do
    terms = terms(query, :query)

    if terms == [] or String.length(String.trim(query)) < @min_query_length do
      []
    else
      limit = int_opt(opts, :limit, @default_limit, @max_limit)

      per_video =
        int_opt(opts, :moments_per_video, @default_moments_per_video, @max_moments_per_video)

      scope = %{
        space_id: space.id,
        archived: Keyword.get(opts, :archived, false) == true,
        collection_ids: collection_tree(space, Keyword.get(opts, :collection))
      }

      moments = matching_moments(scope, terms, limit, per_video)
      title_ids = title_matches(scope, title_words(query), limit)
      embeds = load_embeds(Enum.uniq(title_ids ++ Map.keys(moments)))

      embeds
      |> Enum.map(fn embed ->
        found = Map.get(moments, embed.id, [])
        title? = embed.id in title_ids

        %{
          embed: embed,
          score: score(found, title?),
          matched_on: matched_on(found, title?),
          moments: found |> Enum.map(&public_moment(&1, terms)) |> Enum.take(per_video)
        }
      end)
      |> Enum.sort_by(&{-&1.score, -DateTime.to_unix(&1.embed.inserted_at, :microsecond)})
      |> Enum.take(limit)
    end
  end

  @doc """
  Splits text into lowercase, accent-free search terms. Used for indexed text
  and for queries, so both sides agree on what a word is.
  """
  @spec terms(String.t(), :all | :query) :: [String.t()]
  def terms(text, mode \\ :query) when is_binary(text) do
    terms =
      text
      |> fold()
      |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

    case mode do
      :all -> terms
      :query -> limit_terms(terms)
    end
  end

  defp limit_terms(terms) do
    terms
    |> Enum.map(&String.slice(&1, 0, @max_term_length))
    |> Enum.uniq()
    |> Enum.take(@max_terms)
  end

  # Titles are matched as typed (case-insensitively), like the title search
  # the dashboard already had.
  defp title_words(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> limit_terms()
  end

  @doc """
  A short excerpt of `text` around the first matching word, as `{text, match?}`
  parts ready to render without trusting the text as markup.
  """
  @spec snippet(String.t(), [String.t()]) :: snippet()
  def snippet(text, terms) when is_binary(text) and is_list(terms) do
    parts =
      ~r/[\p{L}\p{N}]+/u
      |> Regex.split(text, include_captures: true, trim: true)
      |> Enum.map(fn part -> {part, term_match?(part, terms)} end)

    first = Enum.find_index(parts, &elem(&1, 1)) || 0
    {before, rest} = Enum.split(parts, first)

    lead = before |> Enum.reverse() |> take_length(@snippet_lead) |> Enum.reverse()
    tail = take_length(rest, @snippet_length - parts_length(lead))

    prefix = if length(lead) < length(before), do: [{"…", false}], else: []
    suffix = if length(tail) < length(rest), do: [{"…", false}], else: []

    (prefix ++ lead ++ tail ++ suffix)
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map(fn [{_text, hit?} | _] = chunk -> {Enum.map_join(chunk, &elem(&1, 0)), hit?} end)
    |> trim_snippet()
  end

  defp term_match?(part, terms) do
    case terms(part, :all) do
      [] -> false
      words -> Enum.any?(words, fn word -> Enum.any?(terms, &String.starts_with?(word, &1)) end)
    end
  end

  defp take_length(parts, budget) do
    parts
    |> Enum.reduce_while({[], budget}, fn {text, _} = part, {taken, left} ->
      if left <= 0 and taken != [],
        do: {:halt, {taken, left}},
        else: {:cont, {[part | taken], left - String.length(text)}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp parts_length(parts), do: parts |> Enum.map(&String.length(elem(&1, 0))) |> Enum.sum()

  defp trim_snippet([]), do: []

  defp trim_snippet(parts) do
    parts
    |> List.update_at(0, fn {text, hit?} -> {String.trim_leading(text), hit?} end)
    |> List.update_at(-1, fn {text, hit?} -> {String.trim_trailing(text), hit?} end)
    |> Enum.reject(fn {text, _} -> text == "" end)
  end

  defp fold(text) do
    text
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
  end

  # Terms hold only letters and digits, so they cannot change the query syntax.
  defp tsquery(terms), do: Enum.map_join(terms, " & ", &"'#{&1}':*")

  defp matching_moments(scope, terms, limit, per_video) do
    tsquery = tsquery(terms)
    # Candidates per video leave room to drop moments that show the same part.
    candidates = per_video * 4

    ranked =
      from(m in Moment,
        as: :moment,
        join: a in Asset,
        on: a.current_video_id == m.video_id,
        join: e in Embed,
        as: :embed,
        on: e.asset_id == a.id,
        where: m.space_id == ^scope.space_id,
        where: fragment("? @@ to_tsquery('simple', ?)", m.search_vector, ^tsquery),
        select: %{
          embed_id: e.id,
          source: m.source,
          start_ms: m.start_ms,
          end_ms: m.end_ms,
          text: m.text,
          rank: fragment("ts_rank(?, to_tsquery('simple', ?))", m.search_vector, ^tsquery),
          position:
            over(row_number(),
              partition_by: e.id,
              order_by: [
                desc:
                  fragment(
                    "ts_rank(?, to_tsquery('simple', ?))",
                    m.search_vector,
                    ^tsquery
                  ),
                asc: m.start_ms
              ]
            )
        }
      )
      |> accessible(scope)

    from(r in subquery(ranked),
      where: r.position <= ^candidates,
      order_by: [desc: r.rank, asc: r.start_ms],
      limit: ^(limit * candidates)
    )
    |> Repo.all()
    |> Enum.group_by(& &1.embed_id)
    |> Map.new(fn {embed_id, rows} -> {embed_id, distinct_moments(rows)} end)
  end

  defp distinct_moments(rows) do
    rows
    |> Enum.reduce([], fn row, kept ->
      if Enum.any?(kept, &(abs(&1.start_ms - row.start_ms) < @distinct_moment_ms)),
        do: kept,
        else: [row | kept]
    end)
    |> Enum.reverse()
  end

  defp title_matches(_scope, [], _limit), do: []

  defp title_matches(scope, terms, limit) do
    query =
      from(e in Embed,
        as: :embed,
        join: a in Asset,
        on: a.id == e.asset_id,
        order_by: [desc: e.inserted_at],
        limit: ^limit,
        select: e.id
      )

    terms
    |> Enum.reduce(query, fn term, query ->
      pattern = "%" <> escape_like(term) <> "%"
      where(query, [_e, a], fragment("lower(?) LIKE ?", a.name, ^pattern))
    end)
    |> accessible(scope)
    |> Repo.all()
  end

  # Everything a search may return passes through here: the space, live video
  # embeds only, and the requested collection scope.
  defp accessible(query, scope) do
    query =
      where(
        query,
        [embed: e],
        e.space_id == ^scope.space_id and e.type == :video and is_nil(e.deleted_at) and
          e.archived == ^scope.archived
      )

    in_collections(query, scope.collection_ids)
  end

  @doc """
  Limits a query with an `:embed` binding to `collection` and the collections
  nested in it. `nil` leaves the query on the whole space.
  """
  def within_collection(query, %Space{} = space, collection),
    do: in_collections(query, collection_tree(space, collection))

  defp in_collections(query, nil), do: query

  defp in_collections(query, ids) do
    where(
      query,
      [embed: e],
      exists(
        from(ce in CollectionEmbed,
          where: ce.embed_id == parent_as(:embed).id and ce.collection_id in ^ids,
          select: 1
        )
      )
    )
  end

  # The collection and every collection nested in it. `nil` means the whole
  # space; an embed that is not a collection of this space matches nothing.
  defp collection_tree(_space, nil), do: nil

  defp collection_tree(%Space{id: space_id}, %Embed{
         type: :collection,
         space_id: space_id,
         collection_id: root
       })
       when is_binary(root) do
    initial = from(c in Collection, where: c.id == ^root, select: %{id: c.id})

    nested =
      from(folder in Embed,
        join: ce in CollectionEmbed,
        on: ce.embed_id == folder.id,
        join: tree in "collection_tree",
        on: tree.id == ce.collection_id,
        where:
          folder.space_id == ^space_id and folder.type == :collection and
            is_nil(folder.deleted_at) and not is_nil(folder.collection_id),
        select: %{id: folder.collection_id}
      )

    tree = union(initial, ^nested)

    {"collection_tree", Collection}
    |> recursive_ctes(true)
    |> with_cte("collection_tree", as: ^tree)
    |> select([tree], tree.id)
    |> Repo.all()
  end

  defp collection_tree(_space, _collection), do: []

  defp load_embeds([]), do: []

  defp load_embeds(ids) do
    from(e in Embed,
      left_join: a in assoc(e, :asset),
      left_join: v in assoc(a, :current_video),
      left_join: s in assoc(e, :settings),
      where: e.id in ^ids,
      preload: [asset: {a, [current_video: v]}, settings: s]
    )
    |> Repo.all()
  end

  defp score(moments, title?) do
    best = moments |> Enum.map(& &1.rank) |> Enum.max(fn -> 0.0 end)
    # A title match outranks any content match; more moments break ties.
    if(title?, do: 1.0, else: 0.0) + best + min(length(moments), 5) * 0.001
  end

  defp matched_on(moments, title?) do
    sources = moments |> Enum.map(& &1.source) |> Enum.uniq()
    if(title?, do: ["title"], else: []) ++ Enum.filter(@sources, &(&1 in sources))
  end

  defp public_moment(row, terms) do
    %{
      source: row.source,
      start: row.start_ms / 1000,
      end: row.end_ms / 1000,
      text: row.text,
      snippet: snippet(row.text, terms)
    }
  end

  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp int_opt(opts, key, default, max) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> min(value, max)
      _ -> default
    end
  end
end
