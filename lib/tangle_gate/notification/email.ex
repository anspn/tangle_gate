defmodule TangleGate.Notification.Email do
  @moduledoc """
  Email notification service for user lifecycle events.

  Sends SMTP emails when:
  - A user is created
  - A DID is assigned to a user
  - A verifiable credential is issued (user authorized)

  Emails are dispatched asynchronously via `Task.Supervisor` so they
  never block the calling endpoint. Failures are logged but do not
  affect the HTTP response.

  ## Configuration

      config :tangle_gate, TangleGate.Notification.Email,
        enabled: true,
        from: "tangle_gate@tanglegate.dev",
        smtp_relay: "localhost",
        smtp_port: 25,
        smtp_username: "",
        smtp_password: ""
  """

  require Logger

  @doc """
  Notify a user that their account has been created.
  """
  @spec user_created(email :: String.t(), role :: String.t()) :: :ok
  def user_created(email, role) do
    subject = "Welcome to TangleGate"

    body =
      """
      Hello,

      Your TangleGate account has been created.

      Email: #{email}
      Role:  #{role}

      You can log in at your organization's TangleGate portal. An administrator
      will assign you a Decentralized Identifier (DID) and authorize your access
      when ready.

      — TangleGate
      """

    send_async(email, subject, body)
  end

  @doc """
  Notify a user that a DID has been assigned to their account.
  """
  @spec did_assigned(email :: String.t(), did :: String.t()) :: :ok
  def did_assigned(email, did) do
    subject = "DID Assigned — TangleGate"

    body =
      """
      Hello,

      A Decentralized Identifier (DID) has been assigned to your TangleGate account.

      DID: #{did}

      Your DID has been published on-chain. An administrator will issue you a
      Verifiable Credential when ready, which you'll need to access the portal.

      — TangleGate
      """

    send_async(email, subject, body)
  end

  @doc """
  Notify a user that a verifiable credential has been issued (authorized).
  """
  @spec credential_issued(email :: String.t(), did :: String.t()) :: :ok
  def credential_issued(email, did) do
    subject = "Credential Issued — TangleGate"

    body =
      """
      Hello,

      A Verifiable Credential has been issued for your TangleGate account.

      DID: #{did}

      You are now authorized to access the TangleGate portal. Use your
      credential JWT and private key to start a session.

      — TangleGate
      """

    send_async(email, subject, body)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp send_async(to, subject, body) do
    if enabled?() do
      Task.start(fn ->
        case send_email(to, subject, body) do
          :ok ->
            Logger.info("[Email] Sent '#{subject}' to #{to}")

          {:error, reason} ->
            Logger.warning("[Email] Failed to send '#{subject}' to #{to}: #{inspect(reason)}")
        end
      end)
    else
      Logger.debug("[Email] Notifications disabled — skipping '#{subject}' to #{to}")
    end

    :ok
  end

  defp send_email(to, subject, body) do
    config = Application.get_env(:tangle_gate, __MODULE__, [])
    from = Keyword.get(config, :from, "tangle_gate@tanglegate.dev")
    relay = Keyword.get(config, :smtp_relay, "localhost")
    port = Keyword.get(config, :smtp_port, 25)
    username = Keyword.get(config, :smtp_username, "")
    password = Keyword.get(config, :smtp_password, "")

    message =
      "From: #{from}\r\n" <>
        "To: #{to}\r\n" <>
        "Subject: #{subject}\r\n" <>
        "Content-Type: text/plain; charset=utf-8\r\n" <>
        "\r\n" <>
        body

    smtp_options = [
      relay: relay,
      port: port,
      no_mx_lookups: true
    ]

    smtp_options =
      if username != "" and password != "" do
        smtp_options ++ [username: username, password: password, auth: :always]
      else
        smtp_options
      end

    case :gen_smtp_client.send_blocking({from, [to], message}, smtp_options) do
      receipt when is_binary(receipt) -> :ok
      {:error, reason} -> {:error, reason}
      {:error, _type, reason} -> {:error, reason}
    end
  end

  defp enabled? do
    config = Application.get_env(:tangle_gate, __MODULE__, [])
    Keyword.get(config, :enabled, false)
  end
end
