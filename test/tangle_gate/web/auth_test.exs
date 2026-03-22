defmodule TangleGate.Web.AuthTest do
  use ExUnit.Case, async: true

  alias TangleGate.Web.Auth

  @test_user %{id: "usr_test", email: "test@example.com", role: :user}

  describe "verify_token_ignoring_expiry/1" do
    test "accepts a valid non-expired token" do
      {:ok, token, _claims} = Auth.generate_token(@test_user)
      assert {:ok, claims} = Auth.verify_token_ignoring_expiry(token)
      assert claims["user_id"] == "usr_test"
      assert claims["email"] == "test@example.com"
      assert claims["role"] == "user"
    end

    test "accepts a token with expired exp claim" do
      # Generate a token, then manually create one with an exp in the past
      signer = Joken.Signer.create("HS256", auth_secret())

      past_exp = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.to_unix()

      extra_claims = %{
        "user_id" => "usr_test",
        "email" => "test@example.com",
        "role" => "user",
        "exp" => past_exp
      }

      {:ok, expired_token, _} = Joken.generate_and_sign(%{}, extra_claims, signer)

      # Strict verification should reject it
      assert {:error, _} = Auth.verify_token(expired_token)

      # Lenient verification should accept it (signature valid, exp ignored)
      assert {:ok, claims} = Auth.verify_token_ignoring_expiry(expired_token)
      assert claims["user_id"] == "usr_test"
      assert claims["exp"] == past_exp
    end

    test "rejects a token with invalid signature" do
      wrong_signer = Joken.Signer.create("HS256", "completely-wrong-secret-key")
      {:ok, bad_token, _} = Joken.generate_and_sign(%{}, %{"user_id" => "x"}, wrong_signer)

      assert {:error, _} = Auth.verify_token_ignoring_expiry(bad_token)
    end

    test "rejects garbage input" do
      assert {:error, _} = Auth.verify_token_ignoring_expiry("not.a.jwt")
      assert {:error, _} = Auth.verify_token_ignoring_expiry("")
    end
  end

  # Read the JWT secret from app config (same as Auth module)
  defp auth_secret do
    Application.get_env(:tangle_gate, TangleGate.Web.Auth, [])[:secret] ||
      "test-secret-change-me"
  end
end
