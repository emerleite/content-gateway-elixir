defmodule ContentGateway do
  defmacro __using__(_opts) do
    quote do
      # alias :exometer, as: Exometer

      require Logger

      def connection_timeout do
        #TODO raise when not override
        1_000
      end

      def request_timeout do
        #TODO raise when not override
        300
      end

      def user_agent do
        "Elixir (Content Gateway)"
      end

      def get(url, [cache_options: cache_options]), do: get(url, headers: %{}, options: %{}, cache_options: cache_options)
      def get(url, [headers: headers, cache_options: cache_options]), do: get(url, headers: headers, options: %{}, cache_options: cache_options)
      def get(url, [options: options, cache_options: cache_options]), do: get(url, headers: %{}, options: options, cache_options: cache_options)
      def get(url, [headers: headers, options: options]), do: get(url, headers: headers, options: options, cache_options: %{})
      def get(url, [headers: headers]), do: get(url, headers: headers, options: %{})
      def get(url, [options: options]), do: get(url, headers: %{}, options: options)
      def get(url, [headers: headers, options: options, cache_options: cache_options]) do
        case Cachex.get(:content_gateway_cache, url) do
          {:ok, value} ->
            Logger.debug "[HIT] #{url}"
            {:ok, value}
          {:missing, nil} ->
            url
            |> request(headers, options)
            |> process_response(url, cache_options[:expires_in], cache_options[:stale_expires_in])
        end
      end
      def get(url, [headers: headers, options: options, cache_options: %{skip: true}]) do
        request(url, headers, options)
      end
      def get(url) do
        request(url)
      end

      def clear_cache(url) do
        Cachex.del(:content_gateway_cache, url)
        Cachex.del(:content_gateway_cache, "stale:#{url}")
      end

      defp request(url, headers \\ %{}, options \\ %{}) do
        before_time = :os.timestamp

        response =
          case HTTPoison.get(url, headers |> merge_request_headers, options |> merge_request_options) do
            {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> {:ok, body}
            {:ok, %HTTPoison.Response{status_code: 400, body: body}} -> {:bad_request, body}
            {:ok, %HTTPoison.Response{status_code: 401, body: body}} -> {:unauthorized, body}
            {:ok, %HTTPoison.Response{status_code: 403, body: body}} -> {:forbidden, body}
            {:ok, %HTTPoison.Response{status_code: 404, body: body}} -> {:not_found, body}
            {:ok, %HTTPoison.Response{status_code: status, body: body}} -> {:error, "Request failed [url:#{url}] [status:#{status}]"}
            {:error, %HTTPoison.Error{reason: reason}} -> {:error, "Request Error [url:#{url}] - [#{reason}]"}
          end

        after_time = :os.timestamp
        diff       = :timer.now_diff after_time, before_time
        host       = URI.parse(url).host

        # app_name = Application.get_env(:config_scope, :app_name)
        # Exometer.update [app_name, :external, "resp_time", host], diff
        # Exometer.update [app_name, :external, "resp_count", host], 1

        response
      end

      defp merge_request_headers(headers) do
        headers
        |> Map.merge(%{"User-Agent" => user_agent})
      end
      defp merge_request_options(options) do
        %{timeout: connection_timeout, recv_timeout: request_timeout}
        |> Map.merge(options)
        |> Map.to_list
      end

      defp parse_data(body) do
        case Poison.Parser.parse(body) do
          {:ok, json_data} -> json_data
          {:error, reason} ->
            Logger.error "Error parsing json data:#{body} - reason:#{reason}"
            :parse_error
        end
      end

      defp process_response({:bad_request, body}, url, _expires_in, _stale_expires_in) do
        Logger.info "Bad Request [url:#{url}]"
        {:error, :bad_request}
      end
      defp process_response({:unauthorized, body}, url, _expires_in, _stale_expires_in) do
        Logger.info "Unauthorized [url:#{url}]"
        {:error, :unauthorized}
      end
      defp process_response({:forbidden, body}, url, _expires_in, _stale_expires_in) do
        Logger.info "Forbidden [url:#{url}]"
        {:error, :forbidden}
      end
      defp process_response({:not_found, body}, url, _expires_in, _stale_expires_in) do
        Logger.info "Resource Not Found [url:#{url}]"
        {:error, :not_found}
      end
      defp process_response({:error, message}, url, _expires_in, _stale_expires_in) do
        case Cachex.get(:content_gateway_cache, "stale:#{url}") do
          {:ok, value} ->
            Logger.info "[STALE] #{url}"
            {:ok, value}
          {:missing, nil} ->
            Logger.warn message
            {:error, :no_stale}
        end
      end
      defp process_response({:ok, body}, url, expires_in, stale_expires_in) do
        Logger.info "[MISS] #{url}"
        body
        |> parse_data
        |> store_on_cache(url, expires_in, stale_expires_in)
        |> make_response
      end

      defp make_response(:parse_error), do: {:error, :parse_error}
      defp make_response(data), do: {:ok, data}

      defp store_on_cache(data, key, expires_in, nil), do: store_on_cache(data, key, expires_in)
      defp store_on_cache(:parse_error, _key, _expires_in), do: :parse_error
      defp store_on_cache(data, key, expires_in, stale_expires_in) do
        data
        |> store_on_cache(key, expires_in)
        |> store_on_cache("stale:#{key}", stale_expires_in)
      end
      defp store_on_cache(data, key, expires_in) when is_function(expires_in) do
        Cachex.set(:content_gateway_cache, key, data, [ttl: expires_in.(data)])
        data
      end
      defp store_on_cache(data, key, expires_in) do
        Cachex.set(:content_gateway_cache, key, data, [ttl: expires_in])
        data
      end

      defoverridable [connection_timeout: 0, request_timeout: 0, user_agent: 0]
    end
  end
end
