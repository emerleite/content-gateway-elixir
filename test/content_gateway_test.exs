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
  @stale_key "stale:#{@host}"
  @cache_name :content_gateway_cache

  @empty_options %{headers: %{}, options: %{}, cache_options: %{}}
  @default_options %{
    headers: %{"Content-Type" => "application/json"},
    options: %{timeout: :timer.seconds(10), recv_timeout: :timer.seconds(5)},
    cache_options: %{expires_in: :timer.minutes(2), stale_expires_in: :timer.minutes(3)},
  }

  @successful_response %{"status" => "success"}
  @fake_response_200 %HTTPoison.Response{
    status_code: 200,
    body: "{\"status\":\"success\"}"
  }
  @fake_response_500 %HTTPoison.Response{
    status_code: 500,
    body: "{\"message\":\"Internal server error\"}"
  }

  defp stub_httpoison_200(_, _, _), do: {:ok, @fake_response_200}
  defp stub_httpoison_500(_, _, _), do: {:ok, @fake_response_500}
  defp stub_cachex_found(_, _), do: {:ok, @successful_response}
  defp stub_cachex_missing(_, _), do: {:missing, nil}
  defp stub_cachex_set(_, _, _), do: {:ok, true}
  defp stub_cachex_set(_, _, _, _), do: {:ok, true}

  setup do
    Cachex.clear(@cache_name)
    :ok
  end

  defmacro stub_httpoison_success_cachex_ok(expression) do
    quote do
      with_mocks([
        {HTTPoison, [], [get: &stub_httpoison_200/3]},
        {Cachex, [], [get: &stub_cachex_found/2, set: &stub_cachex_set/3, set: &stub_cachex_set/4]}
      ], unquote(expression))
    end
  end

  defmacro stub_httpoison_success_cachex_missing(expression) do
    quote do
      with_mocks([
        {HTTPoison, [], [get: &stub_httpoison_200/3]},
        {Cachex, [], [get: &stub_cachex_missing/2, set: &stub_cachex_set/3, set: &stub_cachex_set/4]}
      ], unquote(expression))
    end
  end

  defmacro stub_httpoison_error(expression) do
    quote do
      #with_mocks(HTTPoison, [get: &stub_httpoison_500/3], unquote(expression))

      with_mocks([
        {HTTPoison, [], [get: &stub_httpoison_500/3]},
        {Cachex, [], [get: &stub_cachex_missing/2, set: &stub_cachex_set/3, set: &stub_cachex_set/4]}
      ], unquote(expression))
    end
  end

  defmacro stub_httpoison_4xx(status, expression) do
    quote do
      custom_response_to_return = %HTTPoison.Response{
        status_code: unquote(status),
        body: "{\"message\":\"Whatever\"}"
      }

      with_mock(HTTPoison, [get: fn(_, _, _) -> {:ok, custom_response_to_return} end], unquote(expression))
    end
  end

  describe "#get" do
    test "must request when cache_options is not passed" do
      options = @default_options |> Map.delete(:cache_options)
      stub_httpoison_success_cachex_missing do
        GenericApi.get(@host, options)
        assert called HTTPoison.get(@host, :_, :_)
      end
    end

    test "must request when [:cache_options][:skip] is true" do
      stub_httpoison_success_cachex_ok do
        skip_cache = %{cache_options: %{skip: true}}
        GenericApi.get(@host, @empty_options |> Map.merge(skip_cache))
        assert called HTTPoison.get(@host, :_, :_)
        refute called Cachex.get(@cache_name, @host)
      end
    end

    test "do not use cache when no options are passed" do
      stub_httpoison_success_cachex_ok do
        GenericApi.get(@host)
        assert called HTTPoison.get(@host, :_, :_)
        refute called Cachex.get(@cache_name, @host)
      end
    end

    test "can receive only cache options" do
      stub_httpoison_success_cachex_ok do
        GenericApi.get(@host, %{cache_options: %{skip: true}})
        assert called HTTPoison.get(@host, :_, :_)
        refute called Cachex.get(@cache_name, @host)
      end
    end

    test "do not request the same url twice if it is cached" do
      stub_httpoison_success_cachex_missing do
        GenericApi.get(@host, @default_options)
        assert called HTTPoison.get(@host, :_, :_)
        assert called Cachex.set(@cache_name, @host, :_, :_)
      end
      stub_httpoison_success_cachex_ok do
        GenericApi.get(@host, @default_options)
        assert called Cachex.get(@cache_name, @host)
        refute called HTTPoison.get(@host, :_, :_)
      end
    end

    test "do not cache errors" do
      stub_httpoison_error do
        GenericApi.get(@host, @default_options)
        refute called Cachex.set(:_, :_, :_)
        refute called Cachex.set(:_, :_, :_, :_)
      end
      with_mock(HTTPoison, [get: &stub_httpoison_200/3]) do
        assert GenericApi.get(@host, @default_options) == {:ok, @successful_response}
        assert called HTTPoison.get(@host, :_, :_)
      end
    end

    test "use default options when only the url is specified" do
      expected_headers = %{"User-Agent" => GenericApi.user_agent()}
      expected_options = [
        hackney: [pool: GenericApi.caller_module()],
        recv_timeout: GenericApi.request_timeout(),
        timeout: GenericApi.connection_timeout()
      ]

      stub_httpoison_success_cachex_missing do
        GenericApi.get(@host)
        assert called HTTPoison.get(@host, expected_headers, expected_options)
      end
    end

    test "returns stale data (if exists) on error" do
      #Making sure there is no stale data on cache.
      assert Cachex.get(@cache_name, @host) == {:missing, nil}
      assert Cachex.get(@cache_name, @stale_key) == {:missing, nil}

      #Puting some data on cache
      fake_response = %HTTPoison.Response{
        status_code: 200,
        body: "{\"data\":\"staled\"}"
      }
      HTTPoison
      |> with_mock [get: fn(_, _, _) -> {:ok, fake_response} end] do
        GenericApi.get(@host, @default_options)
        assert called HTTPoison.get(@host, :_, :_)
        assert Cachex.get(@cache_name, @host) == {:ok, %{"data" => "staled"}}
      end

      #Making sure that stale data will be returned on unsuccessful requests
      HTTPoison
      |> with_mock [get: &stub_httpoison_500/3] do
        assert GenericApi.get(@host, @default_options) == {:ok, %{"data" => "staled"}}
      end
    end

    test "wont skip cache if any options is present" do
      expiring = %{expires_in: :timer.minutes(2), stale_expires_in: :timer.minutes(3)}
      stub_httpoison_success_cachex_ok do
        GenericApi.get(@host, %{cache_options: expiring})
        assert called Cachex.get(@cache_name, @host)
        refute called HTTPoison.get(@host, :_, :_)
      end
    end

    test "always return a tuple" do
      stub_httpoison_success_cachex_ok do
        assert GenericApi.get(@host, @default_options) == {:ok, %{"status" => "success"}}
      end
    end

    test "returns 4xx errors with description" do
      stub_httpoison_4xx 400 do
        assert GenericApi.get(@host) == {:error, :bad_request}
      end
      stub_httpoison_4xx 401 do
        assert GenericApi.get(@host) == {:error, :unauthorized}
      end
      stub_httpoison_4xx 403 do
        assert GenericApi.get(@host) == {:error, :forbidden}
      end
      stub_httpoison_4xx 404 do
        assert GenericApi.get(@host) == {:error, :not_found}
      end
    end

    test "returns an error if there is no stale data on cache" do
      stub_httpoison_error do
        assert GenericApi.get(@host, %{cache_options: %{skip: false}}) == {:error, :no_stale}
        assert called HTTPoison.get(@host, :_, :_)
      end
    end

    test "cache will expire" do
      stub_httpoison_success_cachex_ok do
        cache_expires_in = %{cache_options: %{expires_in: :timer.seconds(1)}}
        assert GenericApi.get(@host, cache_expires_in) == {:ok, %{"status" => "success"}}
      end
      :timer.sleep(1_100) #waiting cache expires
      stub_httpoison_error do
        forces_cache = %{headers: %{}, options: %{}, cache_options: %{skip: false}}
        assert GenericApi.get(@host, forces_cache) == {:error, :no_stale}
      end
    end

    test "gets caller module" do
      assert GenericApi.caller_module == :contentgatewaytest_genericapi
    end
  end
end
