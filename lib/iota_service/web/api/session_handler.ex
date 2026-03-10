defmodule IotaService.Web.API.SessionHandler do
  @moduledoc """
  TTY Session Recording API handler.

  All routes require JWT authentication (via `Authenticate` plug).

  ## Endpoints

  - `POST   /api/sessions`              — Start a new recording session
  - `POST   /api/sessions/:id/end`      — End a session (triggers notarization)
  - `GET    /api/sessions`              — List sessions (admin: all, user: own)
  - `GET    /api/sessions/:id`          — Get session details
  - `GET    /api/sessions/:id/download` — Download session history as JSON file
  """

  use Plug.Router

  import Plug.Conn

  alias IotaService.Session.Manager
  alias IotaService.Web.API.Helpers
  alias IotaService.Web.Auth

  # Auth is handled per-route: most routes use strict JWT validation,
  # but POST /:id/end uses lenient auth (signature only, ignoring exp)
  # so that sessions can be ended even after the token expires.
  plug(:match)
  plug(:authenticate)
  plug(:dispatch)

  # ---------------------------------------------------------------------------
  # Auth — route-aware plug
  # ---------------------------------------------------------------------------

  defp authenticate(%{path_info: path_info} = conn, _opts) do
    if lenient_auth_path?(path_info) do
      do_authenticate(conn, :lenient)
    else
      do_authenticate(conn, :strict)
    end
  end

  # POST /:session_id/end → ["ses_xxx", "end"]
  defp lenient_auth_path?([_, "end"]), do: true
  defp lenient_auth_path?(_), do: false

  defp do_authenticate(conn, mode) do
    with {:ok, token} <- extract_bearer_token(conn),
         {:ok, claims} <- verify_token(token, mode) do
      assign(conn, :current_user, %{
        id: claims["user_id"],
        email: claims["email"],
        role: claims["role"] || "user"
      })
    else
      {:error, :no_token} ->
        conn |> Helpers.unauthorized("Missing Authorization header") |> halt()

      {:error, _reason} ->
        conn |> Helpers.unauthorized("Invalid or expired token") |> halt()
    end
  end

  defp verify_token(token, :strict), do: Auth.verify_token(token)
  defp verify_token(token, :lenient), do: Auth.verify_token_ignoring_expiry(token)

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, String.trim(token)}
      _ -> {:error, :no_token}
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions — Start a new recording session
  # ---------------------------------------------------------------------------
  post "/" do
    params = conn.body_params || %{}
    did = params["did"]
    user = conn.assigns[:current_user]

    cond do
      is_nil(did) || did == "" ->
        Helpers.json(conn, 400, %{
          error: "missing_parameter",
          message: "Required parameter missing: did"
        })

      true ->
        case Manager.start_session(did, user.id) do
          {:ok, session} ->
            Helpers.json(conn, 201, %{
              session_id: session.session_id,
              did: session.did,
              started_at: DateTime.to_iso8601(session.started_at),
              status: to_string(session.status)
            })

          {:error, reason} ->
            Helpers.json(conn, 500, %{
              error: "session_error",
              message: "Failed to start session: #{inspect(reason)}"
            })
        end
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/sessions/:id/end — End a session (triggers notarization)
  # ---------------------------------------------------------------------------
  post "/:session_id/end" do
    user = conn.assigns[:current_user]

    case Manager.get_session(session_id) do
      {:ok, session} ->
        # Verify the user owns this session (or is admin)
        if user.role == "admin" || session.user_id == user.id do
          case Manager.end_session(session_id) do
            {:ok, ended_session} ->
              Helpers.json(conn, 200, serialize_session(ended_session))

            {:error, reason} ->
              Helpers.json(conn, 500, %{
                error: "session_error",
                message: "Failed to end session: #{inspect(reason)}"
              })
          end
        else
          Helpers.json(conn, 403, %{
            error: "forbidden",
            message: "You can only end your own sessions"
          })
        end

      :not_found ->
        Helpers.json(conn, 404, %{
          error: "not_found",
          message: "Session not found: #{session_id}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions — List sessions
  # ---------------------------------------------------------------------------
  get "/" do
    user = conn.assigns[:current_user]
    params = Plug.Conn.fetch_query_params(conn).query_params

    opts =
      []
      |> then(fn o ->
        # Non-admins can only see their own sessions
        if user.role == "admin" do
          if params["user_id"], do: [{:user_id, params["user_id"]} | o], else: o
        else
          [{:user_id, user.id} | o]
        end
      end)
      |> then(fn o ->
        if params["did"], do: [{:did, params["did"]} | o], else: o
      end)
      |> then(fn o ->
        if params["status"], do: [{:status, params["status"]} | o], else: o
      end)
      |> then(fn o ->
        if params["limit"], do: [{:limit, String.to_integer(params["limit"])} | o], else: o
      end)

    sessions = Manager.list_sessions(opts)

    Helpers.json(conn, 200, %{
      sessions: Enum.map(sessions, &serialize_session/1),
      count: length(sessions)
    })
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions/stats — Session statistics
  # ---------------------------------------------------------------------------
  get "/stats" do
    user = conn.assigns[:current_user]

    unless user.role == "admin" do
      Helpers.json(conn, 403, %{
        error: "forbidden",
        message: "Only admins can view session statistics"
      })
    else
      stats = Manager.stats()
      Helpers.json(conn, 200, stats)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions/:id/download — Download session history as JSON file
  # ---------------------------------------------------------------------------
  get "/:session_id/download" do
    user = conn.assigns[:current_user]

    case Manager.get_session(session_id) do
      {:ok, session} ->
        if user.role == "admin" || session.user_id == user.id do
          case Manager.get_session_history(session_id) do
            {:ok, json_binary} ->
              filename = "session_#{session_id}.json"

              conn
              |> put_resp_content_type("application/json")
              |> put_resp_header(
                "content-disposition",
                "attachment; filename=\"#{filename}\""
              )
              |> send_resp(200, json_binary)

            {:error, :no_document} ->
              Helpers.json(conn, 404, %{
                error: "no_document",
                message: "Session document not available (session may still be active)"
              })

            :not_found ->
              Helpers.json(conn, 404, %{
                error: "not_found",
                message: "Session not found: #{session_id}"
              })
          end
        else
          Helpers.json(conn, 403, %{
            error: "forbidden",
            message: "You can only download your own sessions"
          })
        end

      :not_found ->
        Helpers.json(conn, 404, %{
          error: "not_found",
          message: "Session not found: #{session_id}"
        })
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/sessions/:id — Get session details
  # ---------------------------------------------------------------------------
  get "/:session_id" do
    user = conn.assigns[:current_user]

    case Manager.get_session(session_id) do
      {:ok, session} ->
        if user.role == "admin" || session.user_id == user.id do
          Helpers.json(conn, 200, serialize_session(session, include_commands: true))
        else
          Helpers.json(conn, 403, %{
            error: "forbidden",
            message: "You can only view your own sessions"
          })
        end

      :not_found ->
        Helpers.json(conn, 404, %{
          error: "not_found",
          message: "Session not found: #{session_id}"
        })
    end
  end

  match _ do
    Helpers.json(conn, 404, %{error: "not_found", message: "Session route not found"})
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp serialize_session(session, opts \\ []) do
    base = %{
      session_id: session.session_id,
      did: session.did,
      user_id: session.user_id,
      started_at: if(session.started_at, do: DateTime.to_iso8601(session.started_at)),
      ended_at: if(session.ended_at, do: DateTime.to_iso8601(session.ended_at)),
      status: to_string(session.status),
      command_count: session.command_count,
      notarization_hash: session.notarization_hash,
      on_chain_id: session.on_chain_id,
      error: session.error
    }

    if Keyword.get(opts, :include_commands, false) do
      Map.put(base, :commands, session.commands || [])
    else
      base
    end
  end
end
