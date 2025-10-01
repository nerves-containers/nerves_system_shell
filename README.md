# NervesSystemShell

Nerves devices typically only expose an Elixir or Erlang shell prompt. While this is handy,
some tasks are easier to run in a more `bash`-like shell environment. `:nerves_system_shell` adds
support for running a separate SSH daemon that launches a system shell (busybox's `ash` by default)
using `NervesSSH`.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `nerves_system_shell` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nerves_system_shell, "~> 0.1.0"}
  ]
end
```

Then, start the separate daemon in your application. This assumes that you
configured the default daemon using the application environment:

```elixir
# application.ex
def children(_target) do
  [
    # run a second ssh daemon on another port
    # but with all other options being the same
    # as the default daemon on port 22
    {NervesSSH,
     NervesSSH.Options.with_defaults(
       Application.get_all_env(:nerves_ssh)
       |> Keyword.merge(
         name: :shell,
         port: 2222,
         shell: :disabled,
         daemon_option_overrides: [{:ssh_cli, {NervesSystemShell, []}}]
       )
     )}
  ]
end
```

As an alternative to the last step, you may also run the Unix shell in a subsystem
similar to the firmware update functionality. This allows all SSH functionality to run
on a single TCP port, but has the following known issues that cannot be fixed:

* the terminal is only sized correctly after resizing it for the first time
* direct command execution is not possible (e.g. `ssh my-nerves-device -s shell echo foo` will not work)
* correct interactivity requires your ssh client to force pty allocation (e.g. `ssh my-nerves-device -tt -s shell`)
* setting environment variables is not supported (e.g. `ssh -o SetEnv="FOO=Bar" my-nerves-device`)

You can enable the shell subsystem by adding it to the default configuration:

```elixir
# config/target.exs
config :nerves_ssh,
  subsystems: [
    :ssh_sftpd.subsystem_spec(cwd: '/'),
    {'shell', {NervesSystemShell.Subsystem, []}},
  ],
  # ...
```

Then, connect using `ssh your-nerves-device -tt -s shell` (`shell` being the name set in your 
configuration).

Please report any issues you find when trying this functionality.
