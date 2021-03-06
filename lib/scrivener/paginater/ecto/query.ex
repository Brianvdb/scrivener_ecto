defimpl Scrivener.Paginater, for: Ecto.Query do
  import Ecto.Query

  alias Scrivener.{Config, Page}

  @moduledoc false
  
  @spec paginate(Ecto.Query.t, Scrivener.Config.t) :: Scrivener.Page.t
  def paginate(%{joins: joins, group_bys: group_bys} = query,
    %Config{
      page_size: page_size,
      page_number: page_number,
      module: repo,
      caller: _caller,
      options: options})
    when is_list(joins) and length(joins) > 0 and is_list(group_bys) and group_bys == [] do

    # paginate when joins are present in query
    offset = calc_offset(page_size, page_number, options)

    # determine the ids of the entries we want
    stripped_query = query
                     |> exclude(:select)
                     |> exclude(:preload)
                     |> exclude(:group_by)

    # The group_by is needed to de-duplicate. "distinct" doesnt work
    # because the postgres driver adds the distinct column to the order_by
    # clause, which destroys the original ordering of the query.
    ids = stripped_query
          |> select([x], {x.id})
          |> group_by([x], x.id)
          |> offset(^offset)
          |> limit(^page_size)
          |> repo.all()

    # De-group the ids and find entities
    as_ungrouped_ids = Enum.map(ids, fn {str_id} -> str_id end)

    entries = query
               |> where([x], x.id in ^as_ungrouped_ids)
               |> distinct(true)
               |> repo.all()

    # We also need the total count, so we find it out
    count = stripped_query
            |> exclude(:order_by)
            |> select([x], count(x.id, :distinct))
            |> repo.one!()

    total_pages = Float.ceil(count / page_size) |> round()
    allow_overflow_page_number = Keyword.get(options, :allow_overflow_page_number, false)
    page_number =
      if allow_overflow_page_number, do: page_number, else: min(total_pages, page_number)

    # Then we create the Scrivener-compatible page
    %Page{
      page_size: page_size,
      page_number: page_number,
      entries: entries,
      total_entries: count,
      total_pages: total_pages
    }
  end

  @spec paginate(Ecto.Query.t(), Scrivener.Config.t()) :: Scrivener.Page.t()
  def paginate(query, %Config{
        page_size: page_size,
        page_number: page_number,
        module: repo,
        caller: caller,
        options: options
      }) do
    total_entries =
      Keyword.get_lazy(options, :total_entries, fn -> total_entries(query, repo, caller) end)

    total_pages = total_pages(total_entries, page_size)
    allow_overflow_page_number = Keyword.get(options, :allow_overflow_page_number, false)

    page_number =
      if allow_overflow_page_number, do: page_number, else: min(total_pages, page_number)

    %Page{
      page_size: page_size,
      page_number: page_number,
      entries: entries(query, repo, page_number, total_pages, page_size, caller, options),
      total_entries: total_entries,
      total_pages: total_pages
    }
  end

  defp entries(_, _, page_number, total_pages, _, _, _) when page_number > total_pages, do: []

  defp entries(query, repo, page_number, _, page_size, caller, options) do
    offset = Keyword.get_lazy(options, :offset, fn -> page_size * (page_number - 1) end)

    query
    |> offset(^offset)
    |> limit(^page_size)
    |> repo.all(caller: caller)
  end

  defp total_entries(query, repo, caller) do
    total_entries =
      query
      |> exclude(:preload)
      |> exclude(:order_by)
      |> aggregate()
      |> repo.one(caller: caller)

    total_entries || 0
  end

  defp aggregate(%{distinct: %{expr: [_ | _]}} = query) do
    query
    |> exclude(:select)
    |> count()
  end

  defp aggregate(
         %{
           group_bys: [
             %Ecto.Query.QueryExpr{
               expr: [
                 {{:., [], [{:&, [], [source_index]}, field]}, [], []} | _
               ]
             }
             | _
           ]
         } = query
       ) do
    query
    |> exclude(:select)
    |> select([{x, source_index}], struct(x, ^[field]))
    |> count()
  end

  defp aggregate(query) do
    query
    |> exclude(:select)
    |> select(count("*"))
  end

  defp count(query) do
    query
    |> subquery
    |> select(count("*"))
  end

  defp total_pages(0, _), do: 1

  defp total_pages(total_entries, page_size) do
    (total_entries / page_size) |> Float.ceil() |> round
  end
  
  defp calc_offset(page_size, page_number, options) do
    Keyword.get_lazy(options, :offset, fn -> page_size * (page_number - 1) end)
  end
end
