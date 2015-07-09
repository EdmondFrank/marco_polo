defmodule MarcoPolo.Connection do
  @moduledoc false

  use Connection

  require Logger

  alias MarcoPolo.Protocol
  alias MarcoPolo.Document
  alias MarcoPolo.Error
  import MarcoPolo.Protocol.BinaryHelpers

  @protocol 30

  @connection_args [
    "OrientDB binary driver for Elixir",
    "0.0.1-beta",
    {:short, @protocol},
    "client id",
    "ORecordSerializerBinary",
  ]

  @socket_opts [:binary, active: false, packet: :raw]

  @initial_state %{socket: nil,
                   session_id: nil,
                   queue: :queue.new,
                   schema: nil,
                   tail: ""}

  ## Client code.

  def start_link(opts) do
    case Connection.start_link(__MODULE__, opts) do
      {:error, _} = err ->
        err
      {:ok, pid} = res ->
        maybe_fetch_schema(pid, opts)
        res
    end
  end

  def operation(pid, op_name, args) do
    Connection.call(pid, {:operation, op_name, args})
  end

  def fetch_schema(pid) do
    Connection.cast(pid, :fetch_schema)
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
    {host, port, socket_opts} = tcp_connection_opts(s)

    case :gen_tcp.connect(host, port, socket_opts) do
      {:ok, socket} ->
        s = %{s | socket: socket}
        {:ok, [sndbuf: sndbuf, recbuf: recbuf]} = :inet.getopts(socket, [:sndbuf, :recbuf])
        :ok = :inet.setopts(socket, [buffer: max(sndbuf, recbuf)])

        case do_connect(s) do
          {:ok, s} ->
            :inet.setopts(socket, active: :once)
            {:ok, s}
          %Error{} = error ->
            {:stop, error, s}
          {:tcp_error, reason} ->
            {:stop, reason, s}
        end
      {:error, reason} ->
        Logger.error "OrientDB TCP connect error (#{host}:#{port}): #{:inet.format_error(reason)}"
        {:stop, reason, s}
    end
  end

  @doc false
  def handle_call(call, from, s)

  # No socket means there's no TCP connection, we can return an error to the
  # client.
  def handle_call(_call, _from, %{socket: nil} = s) do
    {:reply, {:error, :closed}, s}
  end

  def handle_call({:operation, op_name, args}, from, %{session_id: sid} = s) do
    req = Protocol.encode_op(op_name, [sid|args])
    send_noreply_enqueueing(s, req, {from, op_name})
  end

  @doc false
  def handle_cast(:fetch_schema, %{session_id: sid} = s) do
    args = [sid, {:short, 0}, {:long, 1}, "*:-1", true, false]
    req = Protocol.encode_op(:record_load, args)

    send_noreply_enqueueing(s, req, :fetch_schema)
  end

  @doc false
  def handle_info(msg, state)

  def handle_info({:tcp, socket, msg}, %{session_id: sid, socket: socket} = s) do
    :inet.setopts(socket, active: :once)
    data = s.tail <> msg

    s =
      case :queue.out(s.queue) do
        {{:value, :fetch_schema}, new_queue} ->
          case Protocol.parse_resp(:record_load, data, s.schema) do
            :incomplete ->
              %{s | tail: data}
            {:error, %Error{}, _} ->
              raise "couldn't fetch schema"
            {:ok, ^sid, [resp], rest} ->
              %{s | schema: parse_schema(resp), tail: rest, queue: new_queue}
          end
        {{:value, {from, op_name}}, new_queue} ->
          case Protocol.parse_resp(op_name, data, s.schema) do
            :incomplete ->
              %{s | tail: data}
            {:unknown_property_id, rest} ->
              Connection.reply(from, {:error, :unknown_property_id})
              %{s | tail: rest}
            {:error, error, rest} ->
              Connection.reply(from, {:error, error})
              %{s | tail: rest, queue: new_queue}
            {:ok, ^sid, resp, rest} ->
              Connection.reply(from, {:ok, resp})
              %{s | tail: rest, queue: new_queue}
          end
      end

    {:noreply, s}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = s) do
    Logger.error "TCP closed"
    {:noreply, s}
  end

  def handle_info(msg, s) do
    IO.puts "Received unhandled message: #{inspect msg}"
    {:noreply, s}
  end

  # Helper functions.

  defp tcp_connection_opts(%{opts: opts} = _state) do
    socket_opts = @socket_opts ++ (opts[:socket_opts] || [])
    {to_char_list(opts[:host]), opts[:port], socket_opts}
  end

  defp do_connect(%{socket: socket} = s) do
    case negotiate_protocol(socket) do
      :ok                     -> authenticate(s)
      %Error{} = error        -> error
      {:tcp_error, _} = error -> error
    end
  end

  defp authenticate(%{opts: opts, socket: socket} = s) do
    user     = Keyword.fetch!(opts, :user)
    password = Keyword.fetch!(opts, :password)

    {op, args} = case Keyword.fetch!(opts, :connection) do
      :server                 -> {:connect, [user, password]}
      {:db, db_name, db_type} -> {:db_open, [db_name, db_type, user, password]}
    end

    # The first `nil` is for the session id, that is required to be nil (-1) for
    # first-time connections; the `false` literal is for using token-based auth,
    # which we don't support yet.
    req = Protocol.encode_op(op, [nil|@connection_args] ++ [false] ++ args)

    case :gen_tcp.send(socket, req) do
      :ok ->
        wait_for_connection_response(s, op)
      {:error, reason} ->
        {:tcp_error, reason}
    end
  end

  defp wait_for_connection_response(%{socket: socket} = s, connection_type) do
    case :gen_tcp.recv(socket, 0) do
      {:error, reason} ->
        {:tcp_error, reason}
      {:ok, new_data} ->
        data = s.tail <> new_data

        case Protocol.parse_connection_resp(data, connection_type) do
          :incomplete ->
            wait_for_connection_response(%{s | tail: data}, connection_type)
          {:error, error, rest} ->
            s = %{s | tail: rest}
            {error, s}
          {:ok, -1, [sid, _token], rest} ->
            s = %{s | session_id: sid}
            s = %{s | tail: rest}
            {:ok, s}
        end
    end
  end

  defp negotiate_protocol(socket) do
    case :gen_tcp.recv(socket, 2) do
      {:ok, <<protocol_number :: short>>} ->
        check_protocol_number(protocol_number)
      {:error, reason} ->
        {:tcp_error, reason}
    end
  end

  defp check_protocol_number(protocol_number) do
    supported = Application.get_env(:marco_polo, :supported_protocol)
    if protocol_number >= supported do
      :ok
    else
      %Error{message: "unsupported protocol version, the supported version is >= #{supported}"}
    end
  end

  defp parse_schema(%Document{fields: %{"globalProperties" => properties}}) do
    global_properties =
      for %Document{fields: %{"name" => name, "type" => type, "id" => id}} <- properties,
        into: HashDict.new() do
          {id, {name, type}}
      end

    %{global_properties: global_properties}
  end

  defp send_noreply_enqueueing(%{socket: socket} = s, req, to_enqueue) do
    case :gen_tcp.send(socket, req) do
      :ok ->
        {:noreply, enqueue(s, to_enqueue)}
      {:error, _reason} = error ->
        {:disconnect, error, s}
    end
  end

  defp enqueue(s, what) do
    update_in s.queue, &:queue.in(what, &1)
  end
end
