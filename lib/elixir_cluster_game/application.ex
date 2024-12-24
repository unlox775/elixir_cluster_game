defmodule ElixirClusterGame.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ElixirClusterGameWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:elixir_cluster_game, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ElixirClusterGame.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: ElixirClusterGame.Finch},
      # Start a worker by calling: ElixirClusterGame.Worker.start_link(arg)
      # {ElixirClusterGame.Worker, arg},
      # Start to serve requests, typically the last entry
      ElixirClusterGameWeb.Endpoint,

      # Start libcluster supervisor
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies), [name: ElixirClusterGame.ClusterSupervisor]]},

      # Start the NodeWatcher GenServer
      {ElixirClusterGame.NodeWatcher, []},
      {ElixirClusterGame.ChannelManager, []},
      {ElixirClusterGame.RoshamboLaser.GameState, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ElixirClusterGame.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ElixirClusterGameWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
