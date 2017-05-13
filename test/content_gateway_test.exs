defmodule ContentGatewayTest.GenericApi do
  use ContentGateway

  def connection_timeout, do: 300
  def request_timeout, do: 1_000
  def user_agent, do: "Elixir (User Profile API; Webmedia)"
end

defmodule ContentGatewayTest do
  use ExUnit.Case
  doctest ContentGateway

  import Mock

  alias ContentGatewayTest.GenericApi

  @host "http://whatever.host.com"
  @cache_name :content_gateway_cache
  @default_options %{
    headers: %{"Content-Type" => "application/json"},
    options: %{timeout: :timer.seconds(10), recv_timeout: :timer.seconds(5)},
    cache_options: %{expires_in: :timer.minutes(2), stale_expires_in: :timer.minutes(3)},
  }
  @fake_response_200 %HTTPoison.Response{
    status_code: 200,
    body: "{\"status\":\"success\"}"
  }
  @fake_response_500 %HTTPoison.Response{
    status_code: 500,
    body: "{\"message\":\"Internal server error\"}"
  }

  defp stub_cachex_get(_, _), do: {:missing, nil}
  defp stub_cachex_set_def(_, _, _), do: {:ok, true}

  setup do
    Cachex.clear(:content_gateway_cache)
    :ok
  end

  defmacro stub_httpoison_success(expression) do
    quote do
      with_mock(HTTPoison, [get: fn(_, _, _) -> {:ok, @fake_response_200} end], unquote(expression))
    end
  end

  defmacro stub_httpoison_error(expression) do
    quote do
      with_mock(HTTPoison, [get: fn(_, _, _) -> {:ok, @fake_response_500} end], unquote(expression))
    end
  end

  defmacro stub_cachex_missing(expression) do
    quote do
      with_mock(Cachex, [get: &stub_cachex_get/2, set: &stub_cachex_set_def/3], unquote(expression))
    end
  end


  describe "#get" do
    test "always request when cache_options is not passed" do
      options = @default_options |> Map.delete(:cache_options)
      stub_httpoison_success do
        GenericApi.get(@host, options)
        assert called HTTPoison.get(@host, :_, :_)
      end
      stub_httpoison_success do
        GenericApi.get(@host, options)
        assert called HTTPoison.get(@host, :_, :_)
      end
    end

    test "do not request the same url twice if it is cached" do
      stub_httpoison_success do
        GenericApi.get(@host, @default_options)
        assert called HTTPoison.get(@host, :_, :_)
      end
      stub_httpoison_success do
        GenericApi.get(@host, @default_options)
        refute called HTTPoison.get(@host, :_, :_)
      end
    end

    test "do not cache errors" do
      stub_httpoison_error do
        GenericApi.get(@host, @default_options)
      end
      stub_httpoison_success do
        GenericApi.get(@host, @default_options)
        assert called HTTPoison.get(@host, :_, :_)
      end
    end

    test "use default options when only the url is specified" do
      stub_httpoison_success do
        GenericApi.get(@host)
        assert called HTTPoison.get(@host, %{"User-Agent" => GenericApi.user_agent()}, [recv_timeout: GenericApi.request_timeout(), timeout: GenericApi.connection_timeout()])
      end
    end

    test "return stale on error" do
      stub_httpoison_success do
        GenericApi.get(@host, @default_options)
        assert called HTTPoison.get(@host, :_, :_)
      end
      stub_httpoison_error do
        assert GenericApi.get(@host, @default_options) == {:ok, %{"status" => "success"}}
      end
    end

    test_with_mock "always return a tuple", Cachex, [get: &stub_cachex_get/2, set: &stub_cachex_set_def/3] do
      stub_httpoison_success do
        {:ok, data} = GenericApi.get(@host, @default_options)
        assert data == %{"status" => "success"}
      end
    end

    test "does not skip cache when any cache_options property is specified" do
      expiring = %{expires_in: :timer.minutes(2), stale_expires_in: :timer.minutes(3)}
      stub_cachex_missing do
        stub_httpoison_success do
          GenericApi.get(@host, %{cache_options: expiring})
        end
        assert called Cachex.get(@cache_name, @host)
      end
    end
  end
end
