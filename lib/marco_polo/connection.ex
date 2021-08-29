defmodule MarcoPolo.Connection do
  @moduledoc false

  use Connection

  require Logger

  alias MarcoPolo.Connection.Auth
  alias MarcoPolo.Protocol
  alias MarcoPolo.Document
  alias MarcoPolo.Error

  @socket_opts [:binary, active: false, packet: :raw]

  @timeout 5000

  @initial_state %{
    socket: nil,
    session_id: nil,
    queue: :queue.new,
    schema: nil,
    tail: "",
    transaction_id: 1,
  }

  ## Client code.

  @doc """
  Starts the current `Connection`. If the (successful) connection is to a
  database, fetch the schema.
  """
  @spec start_link(Keyword.t) :: GenServer.on_start
  def start_link(opts) do
    # The first `opts` is the value to pass to the `init/1` callback, the second
    # one is the list of options being passed to `Connection.start_link` (e.g.,
    # `:name` or `:timeout`).
    case Connection.start_link(__MODULE__, opts, opts) do
      {:error, _} = err ->
        err
      {:ok, pid} = res ->
        maybe_fetch_schema(pid, opts)
        res
    end
  end

  @doc """
  Shuts down the connection (asynchronously since it's a cast).
  """
  @spec stop(pid) :: :ok
  def stop(pid) do
    Connection.cast(pid, :stop)
  end

  @doc """
  Performs the operation identified by `op_name` with the connection on
  `pid`. `args` is the list of arguments to pass to the operation.
  """
  @spec operation(pid, atom, [Protocol.encodable_term], Keyword.t) ::
    {:ok, term} | {:error, term}
  def operation(pid, op_name, args, opts) do
    Connection.call(pid, {:operation, op_name, args}, opts[:timeout] || @timeout)
  end

  @doc """
  Does what `operation/3` does but expects no response from OrientDB and always
  returns `:ok`.
  """
  @spec no_response_operation(pid, atom, [Protocol.encodable_term]) :: :ok
  def no_response_operation(pid, op_name, args) do
    Connection.cast(pid, {:operation, op_name, args})
  end

  @doc """
  Fetch the schema and store it into the state.

  Always returns `:ok` without waiting for the schema to be fetched.
  """
  @spec fetch_schema(pid) :: :ok
  def fetch_schema(pid) do
    Connection.call(pid, :fetch_schema)
  end

  defp maybe_fetch_schema(pid, opts) do
    case Keyword.get(opts, :connection) do
      {:db, _, _} -> fetch_schema(pid)
      _           -> nil
    end
  end

  ## Callbacks.

  @doc false
  def init(opts) do
    s = Dict.merge(@initial_state, opts: opts)
    {:connect, :init, s}
  end

  @doc false
  def connect(_info, s) do
    {host, port, socket_opts, timeout} = tcp_connection_opts(s)

    case :gen_tcp.connect(host, port, socket_opts, timeout) do
      {:ok, socket} ->
        s = %{s | socket: socket}
        setup_socket_buffers(socket)

        case Auth.connect(s) do
          {:ok, s} ->
            :inet.setopts(socket, active: :once)
            {:ok, s}
          {:error, error, s} ->
            {:stop, error, s}
          {:tcp_error, reason, s} ->
            {:stop, reason, s}
        end
      {:error, reason} ->
        Logger.error "OrientDB TCP connect error (#{host}:#{port}): #{:inet.format_error(reason)}"
        {:stop, reason, s}
    end
  end

  @doc false
  def disconnect(:stop, %{socket: nil} = s) do
    {:stop, :normal, s}
  end

  def disconnect(:stop, %{socket: socket} = s) do
    :gen_tcp.close(socket)
    {:stop, :normal, %{s | socket: nil}}
  end

  def disconnect(error, s) do
    # We only care about {from, _} tuples, ignoring queued stuff like
    # :fetch_schema.
    for {from, _operation} <- :queue.to_list(s.queue) do
      Connection.reply(from, error)
    end

    # Backoff 0 to churn through all commands in mailbox before reconnecting,
    # https://github.com/ericmj/mongodb/blob/a2dba1dfc089960d87364c2c43892f3061a93924/lib/mongo/connection.ex#L210
    {:backoff, 0, %{s | socket: nil, queue: :queue.new, transaction_id: 1}}
  end

  @doc false
  # No socket means there's no TCP connection, we can return an error to the
  # client.
  def handle_call(_call, _from, %{socket: nil} = s) do
    {:reply, {:error, :closed}, s}
  end

  # We have to handle the :tx_commit operation differently as we have to keep
  # track of the transaction id, which is kept in the state of this genserver
  # (we also have to update this id).
  def handle_call({:operation, :tx_commit, [:transaction_id|args]}, from, s) do
    {id, s} = next_transaction_id(s)
    handle_call({:operation, :tx_commit, [id|args]}, from, s)
  end

  def handle_call({:operation, op_name, args}, from, %{session_id: sid} = s) do
    check_op_is_allowed!(s, op_name)

    req = Protocol.encode_op(op_name, [sid|args])
    s
    |> enqueue({from, op_name})
    |> send_noreply(req)
  end

  def handle_call(:fetch_schema, from, %{session_id: sid} = s) do
    check_op_is_allowed!(s, :record_load)

    args = [sid, {:short, 0}, {:long, 1}, "*:-1", true, false]
    req = Protocol.encode_op(:record_load, args)

    s
    |> enqueue({:fetch_schema, from})
    |> send_noreply(req)
  end

  @doc false
  def handle_cast({:operation, op_name, args}, %{session_id: sid} = s) do
    check_op_is_allowed!(s, op_name)

    req = Protocol.encode_op(op_name, [sid|args])
    send_noreply(s, req)
  end

  def handle_cast(:stop, s) do
    {:disconnect, :stop, s}
  end

  @doc false
  def handle_info({:tcp, socket, msg}, %{socket: socket} = s) do
    :inet.setopts(socket, active: :once)
    s = dequeue_and_parse_resp(s, :queue.out(s.queue), s.tail <> msg)
    {:noreply, s}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = s) do
    {:disconnect, {:error, :closed}, s}
  end

  # Helper functions.

  defp tcp_connection_opts(%{opts: opts} = _state) do
    socket_opts = @socket_opts ++ (opts[:socket_opts] || [])
    {to_char_list(opts[:host]), opts[:port], socket_opts, opts[:timeout] || @timeout}
  end

  defp parse_schema(%Document{fields: %{"globalProperties" => properties}}) do
    global_properties =
      for %Document{fields: %{"name" => name, "type" => type, "id" => id}} <- properties,
        into: HashDict.new() do
          {id, {name, type}}
      end

    %{global_properties: global_properties}
  end

  defp setup_socket_buffers(socket) do
    {:ok, [sndbuf: sndbuf, recbuf: recbuf, buffer: buffer]} =
      :inet.getopts(socket, [:sndbuf, :recbuf, :buffer])

    buffer = buffer |> max(sndbuf) |> max(recbuf)
    :ok = :inet.setopts(socket, [buffer: buffer])
  end

  defp send_noreply(%{socket: socket} = s, req) do
    case :gen_tcp.send(socket, req) do
      :ok ->
        {:noreply, s}
      {:error, _reason} = error ->
        {:disconnect, error, s}
    end
  end

  defp enqueue(s, what) do
    update_in s.queue, &:queue.in(what, &1)
  end

  defp dequeue_and_parse_resp(s, {{:value, {:fetch_schema, from}}, new_queue}, data) do
    sid = s.session_id

    case Protocol.parse_resp(:record_load, data, s.schema) do
      :incomplete ->
        %{s | tail: data}
      {^sid, {:error, _}, _rest} ->
        raise "couldn't fetch schema"
      {^sid, {:ok, {schema, _linked_records}}, rest} ->
        schema = parse_schema(schema)
        Connection.reply(from, schema)
        %{s | schema: schema, tail: rest, queue: new_queue}
    end
  end

  defp dequeue_and_parse_resp(s, {{:value, {from, op_name}}, new_queue}, data) do
    sid = s.session_id

    case Protocol.parse_resp(op_name, data, s.schema) do
      :incomplete ->
        %{s | tail: data}
      {^sid, resp, rest} ->
        Connection.reply(from, resp)
        %{s | tail: rest, queue: new_queue}
    end
  end

  defp check_op_is_allowed!(%{opts: opts}, operation) do
    do_check_op_is_allowed!(Keyword.fetch!(opts, :connection), operation)
  end

  @server_ops ~w(
    shutdown
    db_list
    db_create
    db_exist
    db_drop
  )a

  @db_ops ~w(
    db_close
    db_size
    db_countrecords
    db_reload
    record_load
    record_load_if_version_not_latest
    record_create
    record_update
    record_delete
    command
    tx_commit
  )a

  defp do_check_op_is_allowed!({:db, _, _}, op) when not op in @db_ops do
    raise Error, "must be connected to the server (not a db) to perform operation #{op}"
  end

  defp do_check_op_is_allowed!(:server, op) when not op in @server_ops do
    raise Error, "must be connected to a database to perform operation #{op}"
  end

  defp do_check_op_is_allowed!(_, _) do
    nil
  end

  defp next_transaction_id(s) do
    get_and_update_in(s.transaction_id, &{&1, &1 + 1})
  end
end
