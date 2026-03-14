defmodule IotaService.Application do
  @moduledoc """
  IOTA Service Application

  ## Supervision Tree Structure

  ```
  IotaService.Application (rest_for_one)
  ├── IotaService.NIF.Loader          # Ensures NIF is loaded before other services
  ├── IotaService.Store.Repo           # MongoDB connection pool
  ├── IotaService.Identity.Supervisor  # DID-related services (one_for_one)
  │   ├── IotaService.Identity.Server  # GenServer for DID operations
  │   └── IotaService.Identity.Cache   # ETS-backed DID document cache
  ├── IotaService.Notarization.Supervisor  # Notarization services (one_for_one)
  │   ├── IotaService.Notarization.Server  # GenServer for notarization ops
  │   └── IotaService.Notarization.Queue   # Pending notarization queue
  ├── IotaService.Session.Supervisor   # TTY session services (one_for_one)
  │   └── IotaService.Session.Manager  # Session recording & notarization
  └── Bandit (HTTP server)             # Serves REST API + frontend
      └── IotaService.Web.Router       # Plug router
  ```

  ## Strategy Rationale

  - **rest_for_one** at root: If NIF.Loader crashes, restart everything downstream
    since all services depend on the NIF being loaded.
  - **one_for_one** for domain supervisors: Independent services within a domain
    should not affect each other.
  - MongoDB pool starts early so all domain services can persist data.
  - Bandit starts last so all services are ready before accepting HTTP.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting IOTA Service application")

    # Load secrets from Vault before building the supervision tree
    # so config values are available to child processes.
    IotaService.Vault.Client.load_secrets()

    children =
      [
        # 1. NIF Loader - must start first
        # If this crashes, all downstream services restart
        IotaService.NIF.Loader
      ] ++ repo_children() ++ [
        # 3. Identity Domain Supervisor
        {IotaService.Identity.Supervisor, []},

        # 4. Notarization Domain Supervisor
        {IotaService.Notarization.Supervisor, []},

        # 5. Session Recording Supervisor
        {IotaService.Session.Supervisor, []}
      ] ++ web_children()

    # rest_for_one: if NIF.Loader crashes, restart Identity and Notarization supervisors
    opts = [strategy: :rest_for_one, name: IotaService.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Ensure MongoDB indexes after the pool is running
        ensure_mongo_indexes()
        Logger.info("IOTA Service started successfully")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start IOTA Service: #{inspect(reason)}")
        error
    end
  end

  @impl true
  def stop(_state) do
    Logger.info("Stopping IOTA Service application")
    :ok
  end

  # Start MongoDB pool unless disabled (e.g. in test env)
  defp repo_children do
    if Application.get_env(:iota_service, :start_repo, true) do
      [IotaService.Store.Repo]
    else
      []
    end
  end

  # Start Bandit HTTP server unless disabled (e.g. in test env)
  defp web_children do
    if Application.get_env(:iota_service, :start_web, true) do
      port = Application.get_env(:iota_service, :port, 4000)
      Logger.info("Starting web server on 0.0.0.0:#{port}")

      [{Bandit, plug: IotaService.Web.Router, port: port, ip: {0, 0, 0, 0}}]
    else
      []
    end
  end

  # Create MongoDB indexes after the pool is live. Errors are logged but
  # don't prevent the application from starting (indexes may already exist).
  defp ensure_mongo_indexes do
    if Application.get_env(:iota_service, :start_repo, true) do
      IotaService.Store.NotarizationStore.ensure_indexes()
    end
  rescue
    e ->
      Logger.warning("MongoDB index creation failed: #{Exception.message(e)}. " <>
        "Indexes can be created manually later.")
  end
end
