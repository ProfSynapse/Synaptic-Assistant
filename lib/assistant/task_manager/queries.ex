# lib/assistant/task_manager/queries.ex — CRUD and search layer for task management.
#
# Provides all database operations for the Task domain: create, read, update,
# soft-delete, full-text search, dependency management (with cycle detection),
# comments, and audit history.
#
# Used by:
#   - Task skill handlers (lib/assistant/skills/tasks/*.ex) for LLM-driven task ops
#   - Orchestrator.Context for active task summaries in LLM context
#   - Future: REST/GraphQL controllers
#
# Depends on:
#   - Assistant.Repo (Ecto repository)
#   - Assistant.Schemas.{Task, TaskDependency, TaskComment, TaskHistory}

defmodule Assistant.TaskManager.Queries do
  @moduledoc """
  CRUD, search, and dependency management for tasks.

  All functions return `{:ok, result}` or `{:error, reason}` tuples.
  Multi-step mutations (update + history logging) use `Ecto.Multi` for atomicity.

  ## Short ID Generation

  Tasks are assigned human-friendly short IDs like "T-001". Generation uses
  a DB-level `SELECT MAX(short_id)` approach with a retry loop to handle
  concurrent inserts safely.

  ## Full-Text Search

  The `tasks` table has a generated `search_vector` tsvector column that
  combines title (weight A) and description (weight B). Search uses
  `plainto_tsquery` for natural language queries against the GIN index.

  ## Dependency Cycle Detection

  `add_dependency/2` validates that adding a new edge would not create a
  cycle in the task dependency graph, using BFS traversal from the blocked
  task through existing blocking chains.
  """

  import Ecto.Query

  alias Assistant.Repo
  alias Assistant.Schemas.Task
  alias Assistant.Schemas.TaskComment
  alias Assistant.Schemas.TaskDependency
  alias Assistant.Schemas.TaskHistory
  alias Ecto.Multi

  require Logger

  @short_id_prefix "T-"
  @max_short_id_retries 3

  # Fields that are tracked in task_history when changed via update_task/2
  @tracked_fields ~w(title description status priority tags due_date due_time
                     assignee_id parent_task_id archive_reason)a

  # Whitelist of known option keys for normalize_opts/1.
  # Unknown string keys are silently dropped to avoid atom exhaustion attacks.
  @known_opt_keys %{
    "query" => :query,
    "status" => :status,
    "priority" => :priority,
    "assignee_id" => :assignee_id,
    "tags" => :tags,
    "due_before" => :due_before,
    "due_after" => :due_after,
    "include_archived" => :include_archived,
    "limit" => :limit,
    "offset" => :offset,
    "sort_by" => :sort_by,
    "sort_order" => :sort_order,
    "user_id" => :user_id
  }

  # --------------------------------------------------------------------
  # Create
  # --------------------------------------------------------------------

  @doc """
  Creates a new task with an auto-generated short_id.

  ## Parameters

    * `attrs` - Map of task attributes. `:title` is required.

  ## Returns

    * `{:ok, task}` on success
    * `{:error, changeset}` on validation failure
  """
  @spec create_task(map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def create_task(attrs) do
    attrs = Map.put_new(attrs, :short_id, generate_short_id())

    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, task} ->
        {:ok, task}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if short_id_conflict?(errors) do
          retry_create_with_new_short_id(attrs, @max_short_id_retries)
        else
          {:error, changeset}
        end
    end
  end

  defp retry_create_with_new_short_id(_attrs, 0) do
    {:error, :short_id_generation_failed}
  end

  defp retry_create_with_new_short_id(attrs, retries_left) do
    attrs = Map.put(attrs, :short_id, generate_short_id())

    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, task} ->
        {:ok, task}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if short_id_conflict?(errors) do
          retry_create_with_new_short_id(attrs, retries_left - 1)
        else
          {:error, changeset}
        end
    end
  end

  defp short_id_conflict?(errors) do
    Enum.any?(errors, fn
      {:short_id, {_msg, [constraint: :unique, constraint_name: _]}} -> true
      _ -> false
    end)
  end

  # --------------------------------------------------------------------
  # Read
  # --------------------------------------------------------------------

  @doc """
  Fetches a task by UUID `id` or `short_id` string (e.g., "T-001").

  The 1-arity version is for internal/system use (no ownership check).
  The 2-arity version scopes by `creator_id` for user-facing operations.

  Preloads subtasks, comments (with author), and history entries.

  ## Returns

    * `{:ok, task}` with preloaded associations
    * `{:error, :not_found}` if no task matches (or user doesn't own it)
  """
  @spec get_task(String.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def get_task(id_or_short_id) do
    base_task_query(id_or_short_id)
    |> preload([:subtasks, comments: :author, history: []])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  @spec get_task(String.t(), String.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def get_task(id_or_short_id, user_id) do
    base_task_query(id_or_short_id)
    |> where([t], t.creator_id == ^user_id)
    |> preload([:subtasks, comments: :author, history: []])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  defp base_task_query(id_or_short_id) do
    if uuid?(id_or_short_id) do
      from(t in Task, where: t.id == ^id_or_short_id)
    else
      from(t in Task, where: t.short_id == ^id_or_short_id)
    end
  end

  # --------------------------------------------------------------------
  # Update
  # --------------------------------------------------------------------

  @doc """
  Updates a task and logs all changed tracked fields to task_history.

  Uses `Ecto.Multi` to ensure the update and history entries are atomic.

  The 2-arity version is for internal/system use (no ownership check).
  The 3-arity version verifies `creator_id` matches `user_id` before updating.

  ## Parameters

    * `id` - Task UUID
    * `attrs` - Map of fields to update
    * `user_id` - (3-arity) UUID of the requesting user for ownership check

  ## Returns

    * `{:ok, task}` with updated task
    * `{:error, :not_found}` if task doesn't exist
    * `{:error, :unauthorized}` if user doesn't own the task
    * `{:error, changeset}` on validation failure
  """
  @spec update_task(String.t(), map()) :: {:ok, Task.t()} | {:error, term()}
  def update_task(id, attrs) do
    case Repo.get(Task, id) do
      nil ->
        {:error, :not_found}

      task ->
        do_update_task(task, attrs)
    end
  end

  @spec update_task(String.t(), map(), String.t()) :: {:ok, Task.t()} | {:error, term()}
  def update_task(id, attrs, user_id) do
    case Repo.get(Task, id) do
      nil ->
        {:error, :not_found}

      %Task{creator_id: creator_id} when creator_id != user_id ->
        {:error, :unauthorized}

      task ->
        do_update_task(task, attrs)
    end
  end

  defp do_update_task(task, attrs) do
    changeset = Task.changeset(task, attrs)
    changes = changeset.changes

    multi =
      Multi.new()
      |> Multi.update(:task, changeset)
      |> add_history_entries(task, changes, attrs)

    case Repo.transaction(multi) do
      {:ok, %{task: updated_task}} ->
        {:ok, updated_task}

      {:error, :task, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp add_history_entries(multi, task, changes, attrs) do
    user_id = Map.get(attrs, :changed_by_user_id) || Map.get(attrs, "changed_by_user_id")

    conv_id =
      Map.get(attrs, :changed_via_conversation_id) ||
        Map.get(attrs, "changed_via_conversation_id")

    @tracked_fields
    |> Enum.filter(&Map.has_key?(changes, &1))
    |> Enum.reduce(multi, fn field, acc ->
      old_value = Map.get(task, field)
      new_value = Map.get(changes, field)

      history_attrs = %{
        task_id: task.id,
        field_changed: Atom.to_string(field),
        old_value: to_history_string(old_value),
        new_value: to_history_string(new_value),
        changed_by_user_id: user_id,
        changed_via_conversation_id: conv_id
      }

      Multi.insert(acc, {:history, field}, TaskHistory.changeset(%TaskHistory{}, history_attrs))
    end)
  end

  defp to_history_string(nil), do: nil
  defp to_history_string(value) when is_list(value), do: Enum.join(value, ", ")
  defp to_history_string(%Date{} = d), do: Date.to_iso8601(d)
  defp to_history_string(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_history_string(value), do: to_string(value)

  # --------------------------------------------------------------------
  # Soft Delete
  # --------------------------------------------------------------------

  @doc """
  Soft-deletes a task by setting `archived_at` to now.

  The version without `user_id` is for internal/system use.
  Pass `user_id` to enforce ownership before archiving.

  ## Options

    * `:archive_reason` - One of "completed", "cancelled", "superseded"

  ## Returns

    * `{:ok, task}` with archived task
    * `{:error, :not_found}` if task doesn't exist
    * `{:error, :unauthorized}` if user doesn't own the task
    * `{:error, changeset}` on validation failure
  """
  @spec delete_task(String.t(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def delete_task(id, opts \\ []) do
    reason = Keyword.get(opts, :archive_reason, "cancelled")

    update_task(id, %{
      archived_at: DateTime.utc_now(),
      archive_reason: reason
    })
  end

  @spec delete_task(String.t(), keyword(), String.t()) :: {:ok, Task.t()} | {:error, term()}
  def delete_task(id, opts, user_id) do
    reason = Keyword.get(opts, :archive_reason, "cancelled")

    update_task(
      id,
      %{
        archived_at: DateTime.utc_now(),
        archive_reason: reason
      },
      user_id
    )
  end

  # --------------------------------------------------------------------
  # Search (FTS + structured filters)
  # --------------------------------------------------------------------

  @doc """
  Searches tasks using PostgreSQL full-text search on the `search_vector`
  column, combined with structured filters.

  ## Options

    * `:query` - Text query for FTS (uses `plainto_tsquery`)
    * `:status` - Filter by status string
    * `:priority` - Filter by priority string
    * `:assignee_id` - Filter by assignee UUID
    * `:tags` - List of tags to filter by (array overlap)
    * `:due_before` - Date upper bound (inclusive)
    * `:due_after` - Date lower bound (inclusive)
    * `:include_archived` - Include archived tasks (default: false)
    * `:limit` - Max results (default: 50)

  ## Returns

    * List of matching tasks, ordered by FTS rank (if query provided)
      or by priority then due_date.
  """
  @spec search_tasks(keyword() | map()) :: {:error, :user_id_required} | [Task.t()]
  def search_tasks(opts) do
    opts = normalize_opts(opts)
    user_id = opts[:user_id]

    unless user_id do
      {:error, :user_id_required}
    else
      query_text = opts[:query]

      base =
        if query_text && query_text != "" do
          from(t in Task,
            where:
              t.creator_id == ^user_id and
                fragment("search_vector @@ plainto_tsquery('english', ?)", ^query_text),
            order_by: [
              desc: fragment("ts_rank(search_vector, plainto_tsquery('english', ?))", ^query_text)
            ]
          )
        else
          from(t in Task,
            where: t.creator_id == ^user_id,
            order_by: [asc: :priority, asc: :due_date, desc: :inserted_at]
          )
        end

      base
      |> apply_filters(opts)
      |> limit(^(opts[:limit] || 50))
      |> Repo.all()
    end
  end

  # --------------------------------------------------------------------
  # List (filtered + paginated)
  # --------------------------------------------------------------------

  @doc """
  Lists tasks with structured filters, pagination, and sorting.

  ## Options

    * `:status` - Filter by status
    * `:assignee_id` - Filter by assignee
    * `:priority` - Filter by priority
    * `:include_archived` - Include archived tasks (default: false)
    * `:limit` - Page size (default: 20)
    * `:offset` - Pagination offset (default: 0)
    * `:sort_by` - Sort field: `:priority`, `:due_date`, `:inserted_at` (default: `:inserted_at`)
    * `:sort_order` - `:asc` or `:desc` (default: `:desc`)

  ## Returns

    * List of tasks matching filters.
  """
  @spec list_tasks(keyword() | map()) :: {:error, :user_id_required} | [Task.t()]
  def list_tasks(opts \\ []) do
    opts = normalize_opts(opts)
    user_id = opts[:user_id]

    unless user_id do
      {:error, :user_id_required}
    else
      limit_val = opts[:limit] || 20
      offset_val = opts[:offset] || 0
      sort_by = opts[:sort_by] || :inserted_at
      sort_order = opts[:sort_order] || :desc

      sort_by = validate_sort_field(sort_by)
      sort_order = validate_sort_order(sort_order)

      from(t in Task, where: t.creator_id == ^user_id)
      |> apply_filters(opts)
      |> order_by([t], [{^sort_order, field(t, ^sort_by)}])
      |> limit(^limit_val)
      |> offset(^offset_val)
      |> Repo.all()
    end
  end

  defp validate_sort_field(field) when field in [:priority, :due_date, :inserted_at], do: field
  defp validate_sort_field(_), do: :inserted_at

  defp validate_sort_order(order) when order in [:asc, :desc], do: order
  defp validate_sort_order(_), do: :desc

  # --------------------------------------------------------------------
  # Dependencies
  # --------------------------------------------------------------------

  @doc """
  Adds a dependency: `blocking_task_id` must complete before `blocked_task_id`.

  Validates:
    1. No self-dependency (handled by DB constraint)
    2. No cycles in the dependency graph (BFS detection)

  ## Returns

    * `{:ok, dependency}` on success
    * `{:error, :cycle_detected}` if adding this edge would create a cycle
    * `{:error, :self_dependency}` if both IDs are the same
    * `{:error, changeset}` on constraint violation
  """
  @spec add_dependency(String.t(), String.t()) ::
          {:ok, TaskDependency.t()} | {:error, term()}
  def add_dependency(blocking_task_id, blocked_task_id) do
    if blocking_task_id == blocked_task_id do
      {:error, :self_dependency}
    else
      case detect_cycle(blocking_task_id, blocked_task_id) do
        :ok ->
          %TaskDependency{}
          |> TaskDependency.changeset(%{
            blocking_task_id: blocking_task_id,
            blocked_task_id: blocked_task_id
          })
          |> Repo.insert()

        {:error, :cycle_detected} ->
          {:error, :cycle_detected}
      end
    end
  end

  @doc """
  Removes a dependency between two tasks.

  ## Returns

    * `{:ok, dependency}` on success
    * `{:error, :not_found}` if the dependency doesn't exist
  """
  @spec remove_dependency(String.t(), String.t()) ::
          {:ok, TaskDependency.t()} | {:error, :not_found}
  def remove_dependency(blocking_task_id, blocked_task_id) do
    query =
      from(d in TaskDependency,
        where: d.blocking_task_id == ^blocking_task_id and d.blocked_task_id == ^blocked_task_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      dep -> Repo.delete(dep)
    end
  end

  # BFS cycle detection: starting from blocking_task_id, walk upstream
  # through existing blocking chains. If we reach blocked_task_id, adding
  # this edge would create a cycle.
  #
  # The logic: if we add edge (blocking -> blocked), then we need to check
  # whether blocked can already reach blocking through existing edges.
  # "blocked can reach blocking" means: starting from blocking, follow
  # "is blocked by" edges (i.e., existing blocking_task_id chains).
  # If blocked_task_id is found, there's a cycle.
  defp detect_cycle(blocking_task_id, blocked_task_id) do
    # We want to know: can blocked_task_id reach blocking_task_id
    # through existing "blocks" edges?
    # Equivalently: starting from blocked_task_id, follow "blocked_by" edges
    # (where blocked_task_id is the blocked side, find all blocking tasks).
    # If blocking_task_id is reachable, cycle exists.
    visited = MapSet.new([blocked_task_id])
    queue = [blocked_task_id]
    bfs_cycle_check(queue, blocking_task_id, visited)
  end

  defp bfs_cycle_check([], _target, _visited), do: :ok

  defp bfs_cycle_check([current | rest], target, visited) do
    # Find all tasks that block `current`
    blockers =
      from(d in TaskDependency,
        where: d.blocked_task_id == ^current,
        select: d.blocking_task_id
      )
      |> Repo.all()

    if target in blockers do
      {:error, :cycle_detected}
    else
      new_nodes = Enum.reject(blockers, &MapSet.member?(visited, &1))
      new_visited = Enum.reduce(new_nodes, visited, &MapSet.put(&2, &1))
      bfs_cycle_check(rest ++ new_nodes, target, new_visited)
    end
  end

  # --------------------------------------------------------------------
  # Comments
  # --------------------------------------------------------------------

  @doc """
  Adds a comment to a task.

  The 2-arity version is for internal/system use (no ownership check).
  The 3-arity version verifies the task belongs to `user_id` before inserting.

  ## Parameters

    * `task_id` - UUID of the task
    * `attrs` - Map with `:content` (required), optionally `:author_id`,
      `:source_conversation_id`
    * `user_id` - (3-arity) UUID of the requesting user for ownership check

  ## Returns

    * `{:ok, comment}` on success
    * `{:error, :not_found}` if the task doesn't exist or user doesn't own it
    * `{:error, changeset}` on validation failure
  """
  @spec add_comment(String.t(), map()) :: {:ok, TaskComment.t()} | {:error, Ecto.Changeset.t()}
  def add_comment(task_id, attrs) do
    attrs = Map.put(attrs, :task_id, task_id)

    %TaskComment{}
    |> TaskComment.changeset(attrs)
    |> Repo.insert()
  end

  @spec add_comment(String.t(), map(), String.t()) ::
          {:ok, TaskComment.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def add_comment(task_id, attrs, user_id) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :not_found}

      %Task{creator_id: creator_id} when creator_id != user_id ->
        {:error, :not_found}

      _task ->
        add_comment(task_id, attrs)
    end
  end

  @doc """
  Lists comments for a task, ordered by insertion time ascending.

  ## Returns

    * List of comments with preloaded author.
  """
  @spec list_comments(String.t()) :: [TaskComment.t()]
  def list_comments(task_id) do
    from(c in TaskComment,
      where: c.task_id == ^task_id,
      order_by: [asc: c.inserted_at],
      preload: [:author]
    )
    |> Repo.all()
  end

  # --------------------------------------------------------------------
  # History
  # --------------------------------------------------------------------

  @doc """
  Returns the audit trail for a task, ordered by most recent first.

  ## Returns

    * List of history entries with preloaded `changed_by_user`.
  """
  @spec get_history(String.t()) :: [TaskHistory.t()]
  def get_history(task_id) do
    from(h in TaskHistory,
      where: h.task_id == ^task_id,
      order_by: [desc: h.inserted_at],
      preload: [:changed_by_user]
    )
    |> Repo.all()
  end

  # --------------------------------------------------------------------
  # Blocked Status Check
  # --------------------------------------------------------------------

  @doc """
  Checks if a blocked task can be unblocked.

  If the task's status is `:blocked` and all its blocking dependencies have
  status "done", transitions the task to "todo".

  ## Returns

    * `{:ok, task}` — task was unblocked (or was not blocked)
    * `{:error, :not_found}` — task doesn't exist
    * `{:error, :still_blocked}` — some blocking tasks are not done
  """
  @spec check_blocked_status(String.t()) :: {:ok, Task.t()} | {:error, term()}
  def check_blocked_status(task_id) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :not_found}

      %Task{status: status} = task when status != "blocked" ->
        {:ok, task}

      %Task{status: "blocked"} = task ->
        blocking_statuses =
          from(d in TaskDependency,
            where: d.blocked_task_id == ^task_id,
            join: bt in Task,
            on: bt.id == d.blocking_task_id,
            select: bt.status
          )
          |> Repo.all()

        if Enum.all?(blocking_statuses, &(&1 == "done")) do
          update_task(task.id, %{status: "todo"})
        else
          {:error, :still_blocked}
        end
    end
  end

  # --------------------------------------------------------------------
  # Short ID Generation
  # --------------------------------------------------------------------

  @doc """
  Generates the next sequential short_id (e.g., "T-001", "T-002").

  Queries the current maximum short_id from the database and increments.
  Returns "T-001" if no tasks exist yet.
  """
  @spec generate_short_id() :: String.t()
  def generate_short_id do
    max_num =
      from(t in Task,
        where: like(t.short_id, ^"#{@short_id_prefix}%"),
        select: max(fragment("CAST(SUBSTRING(short_id FROM '[0-9]+$') AS INTEGER)"))
      )
      |> Repo.one() || 0

    next = max_num + 1
    @short_id_prefix <> String.pad_leading(Integer.to_string(next), 3, "0")
  end

  # --------------------------------------------------------------------
  # Private Helpers
  # --------------------------------------------------------------------

  defp uuid?(string) do
    case Ecto.UUID.cast(string) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> Enum.flat_map(fn
      {k, v} when is_binary(k) ->
        case Map.get(@known_opt_keys, k) do
          nil -> []
          atom_key -> [{atom_key, v}]
        end

      {k, v} when is_atom(k) ->
        [{k, v}]
    end)
  end

  defp normalize_opts(opts) when is_list(opts), do: opts

  defp apply_filters(query, opts) do
    query
    |> maybe_filter_archived(opts)
    |> maybe_filter_status(opts)
    |> maybe_filter_priority(opts)
    |> maybe_filter_assignee(opts)
    |> maybe_filter_tags(opts)
    |> maybe_filter_due_before(opts)
    |> maybe_filter_due_after(opts)
  end

  defp maybe_filter_archived(query, opts) do
    if opts[:include_archived] do
      query
    else
      where(query, [t], is_nil(t.archived_at))
    end
  end

  defp maybe_filter_status(query, opts) do
    case opts[:status] do
      nil -> query
      status -> where(query, [t], t.status == ^status)
    end
  end

  defp maybe_filter_priority(query, opts) do
    case opts[:priority] do
      nil -> query
      priority -> where(query, [t], t.priority == ^priority)
    end
  end

  defp maybe_filter_assignee(query, opts) do
    case opts[:assignee_id] do
      nil -> query
      assignee_id -> where(query, [t], t.assignee_id == ^assignee_id)
    end
  end

  defp maybe_filter_tags(query, opts) do
    case opts[:tags] do
      nil -> query
      [] -> query
      tags -> where(query, [t], fragment("tags @> ?::text[]", ^tags))
    end
  end

  defp maybe_filter_due_before(query, opts) do
    case opts[:due_before] do
      nil -> query
      date -> where(query, [t], t.due_date <= ^date)
    end
  end

  defp maybe_filter_due_after(query, opts) do
    case opts[:due_after] do
      nil -> query
      date -> where(query, [t], t.due_date >= ^date)
    end
  end
end
