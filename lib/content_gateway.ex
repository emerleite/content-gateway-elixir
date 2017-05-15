defmodule ContentGateway do
  defmacro __using__(_opts) do
    quote do
      require Logger

      @default_options %{headers: %{}, options: %{}, cache_options: %{skip: true}}
      @default_ttl %{}

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
        Logger.debug "Cache will be skipped."
        url
        |> request(headers, options)
        |> report_http_error(url)
        |> process_response
        |> handle_cache(url)
      end
      def get(url, %{headers: headers, options: options, cache_options: cache_options} = all_options) do
        Logger.debug "Trying to get data from cache..."
        case Cachex.get(:content_gateway_cache, url) do
          {:ok, value} ->
            Logger.debug "\t[HIT] #{url}"
            {:ok, value}
          {:missing, nil} ->
            Logger.debug "\t[MISS] #{url}"
            get(url, %{all_options | cache_options: %{skip: true}})
        end
      end
      def get(url, %{} = incomplete_options) do
        Logger.debug "Incomplete options. Content Gateway will merge those options with default_options."
        options = Map.merge(@default_options, incomplete_options)

        if Map.has_key?(incomplete_options, :cache_options) do
          options = put_in(options[:cache_options][:skip], false)
        end

        get(url, options)
      end

      def clear_cache(url) do
        Cachex.del(:content_gateway_cache, url)
        Cachex.del(:content_gateway_cache, "stale:#{url}")
      end

      @lint {Credo.Check.Readability.MaxLineLength, false}
      defp request(url, headers, options) do
        response = url
        |> HTTPoison.get(headers |> merge_request_headers, options |> merge_request_options)
        case response do
          {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> {:ok, body}
          {:ok, %HTTPoison.Response{status_code: 400}} -> as_error :bad_request
          {:ok, %HTTPoison.Response{status_code: 401}} -> as_error :unauthorized
          {:ok, %HTTPoison.Response{status_code: 403}} -> as_error :forbidden
          {:ok, %HTTPoison.Response{status_code: 404}} -> as_error :not_found
          {:ok, %HTTPoison.Response{status_code: status}} -> status |> as_custom_error url
          {:error, %HTTPoison.Error{reason: reason}} -> reason |> as_custom_error url
        end
      end

      defp as_error(description), do: {:error, {description, <<>>}}
      defp as_custom_error(reason, url), do: {:error, "Request failed [url: #{url}] [reason: #{reason}]"}

      defp merge_request_headers(headers) do
        headers
        |> Map.merge(%{"User-Agent" => user_agent()})
      end
      defp merge_request_options(options) do
        %{timeout: connection_timeout(), recv_timeout: request_timeout()}
        |> Map.merge(options)
        |> Map.to_list
      end

      defp report_http_error({:error, {:bad_request, body}} = result, url) do
        Logger.info "Bad Request [url:#{url}]"
        result
      end
      defp report_http_error({:error, {:unauthorized, body}} = result, url) do
        Logger.info "Unauthorized [url:#{url}]"
        result
      end
      defp report_http_error({:error, {:forbidden, body}} = result, url) do
        Logger.info "Forbidden [url:#{url}]"
        result
      end
      defp report_http_error({:error, {:not_found, body}} = result, url) do
        Logger.info "Resource Not Found [url:#{url}]"
        result
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

      defp handle_cache({:ok, body}, key) do
        body
        |> store_on_cache(key)
        |> to_ok_tuple
      end
      defp handle_cache({:ok, body}, key, options) do
        body
        |> store_on_cache(key, options[:expires_in], options[:stale_expires_in])
        |> to_ok_tuple
      end
      defp handle_cache({:error, {message, ""}}, key), do: {:error, message}
      defp handle_cache({:error, message}, key) do
        case Cachex.get(:content_gateway_cache, "stale:#{key}") do
          {:ok, value} ->
            Logger.debug "[STALE] #{key}"
            {:ok, value}
          {:missing, nil} ->
            Logger.warn message
            {:error, :no_stale}
        end
      end

      defp to_ok_tuple(value), do: {:ok, value}

      defp store_on_cache(data, key), do: store_on_cachex(data, key)
      defp store_on_cache(data, key, expires_in), do: store_on_cachex(data, key, expires_in)
      defp store_on_cache(data, key, expires_in, stale_expires_in) do
        data
        |> store_on_cachex(key, expires_in)
        |> store_on_cachex("stale:#{key}", stale_expires_in)
      end

      defp store_on_cachex(data, key) do
        Cachex.set(:content_gateway_cache, key, data)
        data
      end
      defp store_on_cachex(data, key, expires_in) when is_function(expires_in) do
        Cachex.set(:content_gateway_cache, key, data, [ttl: expires_in.(data)])
        data
      end
      defp store_on_cachex(data, key, expires_in) do
        Cachex.set(:content_gateway_cache, key, data, [ttl: expires_in])
        data
      end
    end
  end
end
