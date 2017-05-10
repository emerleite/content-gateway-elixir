defmodule ContentGateway do
  defmacro __using__(_opts) do
    quote do
      require Logger

      @default_options %{headers: %{}, options: %{}, cache_options: %{skip: true}}

      def connection_timeout do
        raise "not implemented"
      end

      def request_timeout do
        raise "not implemented"
      end

      def user_agent do
        "Elixir (Content Gateway)"
      end

      defoverridable [connection_timeout: 0, request_timeout: 0, user_agent: 0]

      def get(url, options \\ %{})
      def get(url, %{headers: headers, options: options, cache_options: %{skip: true}}) do
        url
        |> request(headers, options)
        |> report_http_error(url)
        |> process_response
      end
      def get(url, %{headers: headers, options: options, cache_options: cache_options} = all_options) do
        case Cachex.get(:content_gateway_cache, url) do
          {:ok, value} ->
            Logger.debug "[HIT] #{url}"
            {:ok, value}
          {:missing, nil} ->
            Logger.info "[MISS] #{url}"
            get(url, %{all_options | cache_options: %{skip: true}})
            |> handle_cache(url, cache_options[:expires_in], cache_options[:stale_expires_in])
        end
      end
      def get(url, %{} = incomplete_options) do
        get(url, Map.merge(incomplete_options, @default_options))
      end

      def clear_cache(url) do
        Cachex.del(:content_gateway_cache, url)
        Cachex.del(:content_gateway_cache, "stale:#{url}")
      end

      defp request(url, headers, options) do
        case HTTPoison.get(url, headers |> merge_request_headers, options |> merge_request_options) do
          {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> {:ok, body}
          {:ok, %HTTPoison.Response{status_code: 400, body: body}} -> {:error, {:bad_request, body}}
          {:ok, %HTTPoison.Response{status_code: 401, body: body}} -> {:error, {:unauthorized, body}}
          {:ok, %HTTPoison.Response{status_code: 403, body: body}} -> {:error, {:forbidden, body}}
          {:ok, %HTTPoison.Response{status_code: 404, body: body}} -> {:error, {:not_found, body}}
          {:ok, %HTTPoison.Response{status_code: status, body: body}} -> {:error, "Request failed [url:#{url}] [status:#{status}]"}
          {:error, %HTTPoison.Error{reason: reason}} -> {:error, "Request Error [url:#{url}] - [#{reason}]"}
        end
      end

      defp merge_request_headers(headers) do
        headers
        |> Map.merge(%{"User-Agent" => user_agent()})
      end
      defp merge_request_options(options) do
        %{timeout: connection_timeout(), recv_timeout: request_timeout()}
        |> Map.merge(options)
        |> Map.to_list
      end

      defp report_http_error({:error, {:bad_request, _body}}, url) do
        Logger.info "Bad Request [url:#{url}]"
        {:error, :bad_request}
      end
      defp report_http_error({:error, {:unauthorized, _body}}, url) do
        Logger.info "Unauthorized [url:#{url}]"
        {:error, :unauthorized}
      end
      defp report_http_error({:error, {:forbidden, _body}}, url) do
        Logger.info "Forbidden [url:#{url}]"
        {:error, :forbidden}
      end
      defp report_http_error({:error, {:not_found, _body}}, url) do
        Logger.info "Resource Not Found [url:#{url}]"
        {:error, :not_found}
      end
      defp report_http_error(return, _url), do: return

      defp process_response({:ok, body}) do
        body |> parse_data
      end
      defp process_response({:error, _} = error), do: error

      defp parse_data(body) do
        case Poison.Parser.parse(body) do
          {:ok, json_data} -> {:ok, json_data}
          {:error, reason} ->
            Logger.error "Error parsing json data:#{body} - reason:#{reason}"
            {:error, :parse_error}
        end
      end

      defp handle_cache({:ok, body}, key, expires_in, stale_expires_in), do: store_on_cache(body, key, expires_in, stale_expires_in)
      defp handle_cache({:error, message}, key, _expires_in, _stale_expires_in) do
        case Cachex.get(:content_gateway_cache, "stale:#{key}") do
          {:ok, value} ->
            Logger.info "[STALE] #{key}"
            {:ok, value}
          {:missing, nil} ->
            Logger.warn message
            {:error, :no_stale}
        end
      end

      defp store_on_cache(data, key, expires_in, nil) do
        store_on_cache(data, key, expires_in)
        |> to_ok_tuple
      end
      defp store_on_cache(data, key, expires_in, stale_expires_in) do
        data
        |> store_on_cache(key, expires_in)
        |> store_on_cache("stale:#{key}", stale_expires_in)
        |> to_ok_tuple
      end
      defp store_on_cache(data, key, expires_in) when is_function(expires_in) do
        Cachex.set(:content_gateway_cache, key, data, [ttl: expires_in.(data)])
        data
      end
      defp store_on_cache(data, key, expires_in) do
        Cachex.set(:content_gateway_cache, key, data, [ttl: expires_in])
        data
      end

      defp to_ok_tuple(value), do: {:ok, value}
    end
  end
end
