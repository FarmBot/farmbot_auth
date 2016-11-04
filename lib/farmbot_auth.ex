defmodule FarmbotAuth do
  @moduledoc """
    Gets a token and device information
  """
  @modules Application.get_env(:farmbot_auth, :callbacks) ++ [__MODULE__]

  use Timex
  use GenServer
  require Logger

  def on_token(_token) do
    Logger.debug("GOT TOKEN!")
  end

  @doc """
    Application entry point
  """
  def start(_type, args) do
    Logger.debug("FarmbotAuth Starting.")
    start_link(args)
  end

  @doc """
    Gets the public key from the API
  """
  def get_public_key(server) do
    case HTTPotion.get("#{server}/api/public_key") do
      %HTTPotion.ErrorResponse{message: message} -> {:error, message}
      %HTTPotion.Response{body: body,
                          headers: _headers,
                          status_code: 200}      -> {:ok, RSA.decode_key(body)}
    end
  end

  @doc """
    Encrypts the key with the email, pass, and server
  """
  def encrypt(email, pass, pub_key) do
    f = Poison.encode!(%{"email": email,
                     "password": pass,
                     "id": Nerves.Lib.UUID.generate,
                     "version": 1})
    |> RSA.encrypt({:public, pub_key})
    |> String.Chars.to_string
    {:ok, f}
  end

  @doc """
    Get a token from the server with given token
  """
  def get_token_from_server(secret, server) do
    # I am not sure why this is done this way other than it works.
    payload = Poison.encode!(%{user: %{credentials: :base64.encode_to_string(secret) |> String.Chars.to_string }} )
    case HTTPotion.post "#{server}/api/tokens", [body: payload, headers: ["Content-Type": "application/json"]] do
      # Any other http error.
      %HTTPotion.ErrorResponse{message: reason} -> {:error, reason}
      # bad Password
      %HTTPotion.Response{body: _, headers: _, status_code: 422} -> {:error, :bad_password}
      # Token invalid. Need to try to get a new token here.
      %HTTPotion.Response{body: _, headers: _, status_code: 401} -> {:error, :expired_token}
      # We won
      %HTTPotion.Response{body: body, headers: _headers, status_code: 200} ->
          token = Poison.decode!(body) |> Map.get("token")
          do_callbacks(token)
          {:ok, token}
    end
  end

  @doc """
    Gets the token.
    Will return a token if one exists, nil if not.
    Returns {:error, reason} otherwise
  """
  def get_token do
    GenServer.call(__MODULE__, {:get_token})
  end

  # Genserver stuff
  def init(_args) do
    {:ok, nil}
  end

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__ )
  end

  @doc """
    Log into Farmbot Services. Returns a token, or an error.
  """
  def login(email,pass,server)
    when is_bitstring(email)
     and is_bitstring(pass)
     and is_bitstring(server)
   do
     GenServer.call(__MODULE__, {:login, email,pass,server}, 15000 )
  end

  # This should probably be a cast.
  def handle_call({:login, email,pass,server}, _from, _old_token) do
    thing =
    with {:ok, pub_key}  <- get_public_key(server),
         {:ok, encryped} <- encrypt(email,pass,pub_key),
         do: get_token_from_server(encryped, server)
    {:reply,thing,thing}
  end

  def handle_call({:get_token}, _from, nil) do
    {:reply, nil, nil}
  end

  def handle_call({:get_token}, _from, token) do
    {:reply, token, token}
  end

  def terminate(:normal, state) do
    Logger.debug("AUTH DIED: #{inspect {state}}")
  end

  def terminate(reason, state) do
    Logger.error("AUTH DIED: #{inspect {reason, state}}")
  end

  defp do_callbacks(token) do
    spawn(fn ->
      Enum.all?(@modules, fn(module) ->
        module.on_token(token)
      end)
    end)
  end

end