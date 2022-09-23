defmodule TcpTest.Chat.Room do
  require Logger

  use GenServer

  def start_link(_args) do
    Logger.info("Starting Chat Room server...")
    GenServer.start_link(__MODULE__, %{users: []}, name: __MODULE__)
  end

  def init(init_arg) do
    {:ok, init_arg}
  end

  def handle_cast({:new_message, message, sender_pid}, %{users: users} = state) do
    if username_for_pid(sender_pid, users) do
      process_chat_message(String.trim(message), sender_pid, users)
      {:noreply, state}
    else
      case validate_username(message) do
        {:ok, trimmed_username} ->
          send_to_all_users("* #{trimmed_username} has entered the room", sender_pid, users)

          existing_users_list =
            users
            |> Enum.map(&elem(&1, 1))
            |> Enum.join(",")

          GenServer.cast(
            sender_pid,
            {:send_response, "* The room contains: #{existing_users_list}"}
          )

          Logger.info("Adding #{trimmed_username} to room")
          {:noreply, %{users: [{sender_pid, trimmed_username} | users]}}

        {:error, :invalid_name} ->
          Logger.info("[Room] Name invalid #{message}")
          GenServer.cast(sender_pid, :shutdown)
          {:noreply, %{users: users}}
      end
    end
  end

  def handle_cast({:leave, sender_pid}, %{users: users} = state) do
    users_without_sender = Enum.reject(users, fn {pid, _name} -> pid == sender_pid end)

    if username = username_for_pid(sender_pid, users) do
      send_to_all_users("* #{username} has left the room", sender_pid, users)
    end

    {:noreply, %{users: users_without_sender}}
  end

  defp process_chat_message(message, sender_pid, users) do
    username = username_for_pid(sender_pid, users)

    send_to_all_users("[#{username}] #{message}", sender_pid, users)
  end

  defp validate_username(""), do: {:error, :empty_username}

  defp validate_username(message) do
    with true <- length(String.to_charlist(message)) < 50,
         true <- Regex.replace(~r/[a-zA-Z0-9]+/, String.trim(message), "") == "" do
      Logger.info("TRIMMED = #{String.trim(message)}")
      {:ok, String.trim(message)}
    else
      _ ->
        Logger.error("invalid_name = #{message}")

        {:error, :invalid_name}
    end
  end

  defp send_to_all_users(message, sender_pid, users) do
    username = username_for_pid(sender_pid, users)

    users
    |> Enum.map(fn {client_pid, name} ->
      if client_pid == sender_pid do
        nil
      else
        GenServer.cast(client_pid, {:send_response, message})
      end
    end)
  end

  defp username_for_pid(pid, users) do
    case Enum.find(users, fn {user_pid, name} -> user_pid == pid end) do
      {_pid, username} ->
        username

      nil ->
        nil
    end
  end
end
