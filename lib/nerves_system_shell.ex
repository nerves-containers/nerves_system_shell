defmodule NervesSSHSystemShell.Utils do
  @moduledoc false

  def get_shell_command() do
    cond do
      shell = System.get_env("SHELL") ->
        [shell, "-i"]

      shell = System.find_executable("sh") ->
        [shell, "-i"]

      true ->
        raise "SHELL environment variable not set and sh not available"
    end
  end

  def get_term(nil) do
    if term = System.get_env("TERM") do
      term
    else
      "xterm"
    end
  end

  # erlang pty_ch_msg contains the value of TERM
  # https://www.erlang.org/doc/man/ssh_connection.html#type-pty_ch_msg
  def get_term({term, _, _, _, _, _} = _pty_ch_msg) when is_list(term),
    do: List.to_string(term)
end

defmodule NervesSSHSystemShell do
  @moduledoc """
  A `:ssh_server_channel` that uses `ExPTY` to provide an interactive system shell.

  > #### Warning {: .error}
  >
  > This module does not work when used as an SSH subsystem, as it expects to receive
  > `pty`, `exec` / `shell` ssh messages that are not available when running as a subsystem.
  > If you want to run a Unix shell in a subsystem, have a look at `NervesSSH.SystemShellSubsystem`
  > instead.
  """

  @behaviour :ssh_server_channel

  require Logger

  import NervesSSHSystemShell.Utils

  def child_spec(opts) do
    port = Keyword.fetch!(opts, :port)

    options =
      NervesSSH.Options.with_defaults(
        Application.get_all_env(:nerves_ssh)
        |> Keyword.merge(
          name: :shell,
          port: port,
          shell: :disabled,
          daemon_option_overrides: [{:ssh_cli, {NervesSSHSystemShell, []}}]
        )
      )

    NervesSSH.child_spec(options)
  end

  defp exec_command(cmd, %{pty_opts: pty_opts, env: env}) do
    [file | args] = cmd
    parent = self()

    opts = [
      env: Map.put_new(env, "TERM", get_term(pty_opts)),
      on_data: fn _expty, pty_pid, data -> send(parent, {:pty_data, pty_pid, data}) end,
      on_exit: fn _expty, pty_pid, exit_code, _signal_code ->
        send(parent, {:pty_exit, pty_pid, exit_code})
      end
    ]

    opts =
      case pty_opts do
        nil ->
          opts

        {_term, cols, rows, _, _, _} ->
          opts ++ [cols: cols, rows: rows]
      end

    case ExPTY.spawn(file, args, opts) do
      {:ok, pty_pid} ->
        {:ok, pty_pid, pty_pid}

      error ->
        error
    end
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       pty_pid: nil,
       pty_opts: nil,
       env: %{},
       cid: nil,
       cm: nil
     }}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, connection_manager}, state) do
    {:ok, %{state | cid: channel_id, cm: connection_manager}}
  end

  def handle_msg(
        {:pty_exit, pty_pid, exit_code},
        %{pty_pid: pty_pid, cm: cm, cid: cid} = state
      ) do
    _ = :ssh_connection.exit_status(cm, cid, exit_code)
    _ = :ssh_connection.send_eof(cm, cid)
    {:stop, cid, state}
  end

  def handle_msg({:pty_data, pty_pid, data}, %{cm: cm, cid: cid, pty_pid: pty_pid} = state) do
    _ = :ssh_connection.send(cm, cid, data)
    {:ok, state}
  end

  def handle_msg(msg, state) do
    Logger.error("[NervesSSH.SystemShell] unhandled message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl true
  # client sent a pty request
  def handle_ssh_msg({:ssh_cm, cm, {:pty, cid, want_reply, pty_opts} = _msg}, %{cm: cm} = state) do
    _ = :ssh_connection.reply_request(cm, want_reply, :success, cid)

    {:ok, %{state | pty_opts: pty_opts}}
  end

  # client wants to set an environment variable
  def handle_ssh_msg(
        {:ssh_cm, cm, {:env, cid, want_reply, key, value}},
        %{cm: cm, cid: cid} = state
      ) do
    _ = :ssh_connection.reply_request(cm, want_reply, :success, cid)

    {:ok, update_in(state.env, fn env -> Map.put(env, key, value) end)}
  end

  # client wants to execute a command
  def handle_ssh_msg(
        {:ssh_cm, cm, {:exec, cid, want_reply, command} = _msg},
        state = %{cm: cm, cid: cid}
      )
      when is_list(command) do
    cmd = command |> List.to_string() |> String.split(" ", trim: true)
    {:ok, pty_pid, _} = exec_command(cmd, state)
    _ = :ssh_connection.reply_request(cm, want_reply, :success, cid)
    {:ok, %{state | pty_pid: pty_pid}}
  end

  # client requested a shell
  def handle_ssh_msg(
        {:ssh_cm, cm, {:shell, cid, want_reply} = _msg},
        %{cm: cm, cid: cid} = state
      ) do
    {:ok, pty_pid, _} = exec_command(get_shell_command(), state)
    _ = :ssh_connection.reply_request(cm, want_reply, :success, cid)
    {:ok, %{state | pty_pid: pty_pid}}
  end

  def handle_ssh_msg(
        {:ssh_cm, _cm, {:data, channel_id, 0, data}},
        %{pty_pid: pty_pid, cid: channel_id} = state
      ) do
    _ = ExPTY.write(pty_pid, data)

    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:eof, _}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:signal, _, _} = _msg}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:exit_signal, channel_id, _, _error, _}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:exit_status, channel_id, _status}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg(
        {:ssh_cm, cm, {:window_change, cid, width, height, _, _} = _msg},
        %{pty_pid: pty_pid, cm: cm, cid: cid} = state
      ) do
    _ = ExPTY.resize(pty_pid, width, height)

    {:ok, state}
  end

  def handle_ssh_msg(msg, state) do
    Logger.error("[NervesSSH.SystemShell] unhandled ssh message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end

defmodule NervesSSHSystemShell.Subsystem do
  # maybe merge this into the SystemShell module
  # but not sure yet if it's worth the effort

  @moduledoc """
  A `:ssh_server_channel` that uses `ExPTY` to provide an interactive system shell
  running as an SSH subsystem.

  ## Configuration

  This module accepts a keywordlist for configuring it. Currently, the only supported
  options are:

  * `command` - the command to run when a client connects, defaults to the SHELL
    environment variable or `sh`.

  For example:

  ```elixir
  # config/target.exs
  config :nerves_ssh,
    subsystems: [
      :ssh_sftpd.subsystem_spec(cwd: '/'),
      {'shell', {NervesSSH.SystemShellSubsystem, [command: '/bin/cat']}},
    ],
    # ...
  ```
  """

  @behaviour :ssh_server_channel

  require Logger

  import NervesSSHSystemShell.Utils

  @impl true
  def init(opts) do
    # SSH subsystems do not send :exec, :shell or :pty messages
    command = Keyword.get_lazy(opts, :command, fn -> get_shell_command() end)
    parent = self()

    [file | args] = command

    pty_opts = [
      env: %{"TERM" => get_term(nil)},
      on_data: fn _expty, pty_pid, data -> send(parent, {:pty_data, pty_pid, data}) end,
      on_exit: fn _expty, pty_pid, exit_code, _signal_code ->
        send(parent, {:pty_exit, pty_pid, exit_code})
      end
    ]

    dbg(pty_opts)

    {:ok, pty_pid} = ExPTY.spawn(file, args, pty_opts)

    {:ok, %{pty_pid: pty_pid, cid: nil, cm: nil}}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, connection_manager}, state) do
    {:ok, %{state | cid: channel_id, cm: connection_manager}}
  end

  def handle_msg(
        {:pty_exit, pty_pid, exit_code},
        %{pty_pid: pty_pid, cm: cm, cid: cid} = state
      ) do
    _ = :ssh_connection.exit_status(cm, cid, exit_code)
    _ = :ssh_connection.send_eof(cm, cid)
    {:stop, cid, state}
  end

  def handle_msg({:pty_data, pty_pid, data}, %{pty_pid: pty_pid, cm: cm, cid: cid} = state) do
    _ = :ssh_connection.send(cm, cid, data)
    {:ok, state}
  end

  @impl true
  def handle_ssh_msg(
        {:ssh_cm, cm, {:data, cid, 0, data}},
        %{pty_pid: pty_pid, cm: cm, cid: cid} = state
      ) do
    _ = ExPTY.write(pty_pid, data)

    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:eof, _}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:signal, _, _}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:exit_signal, channel_id, _, _error, _}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:exit_status, channel_id, _status}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg(
        {:ssh_cm, cm, {:window_change, cid, width, height, _, _}},
        %{pty_pid: pty_pid, cm: cm, cid: cid} = state
      ) do
    _ = ExPTY.resize(pty_pid, width, height)

    {:ok, state}
  end

  def handle_ssh_msg(msg, state) do
    Logger.error("[NervesSSH.SystemShellSubsystem] unhandled ssh message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
