defmodule ContentGateway do
  defmacro __using__(_opts) do
    quote do
      require Logger

      @default_options %{headers: %{}, options: %{}, cache_options: %{skip: true}}
      @default_ttl %{}
      @default_pool __MODULE__

      def start_link(opts \\ []) do
        opts = [timeout: 15000, max_connections: 100]
        :hackney_pool.child_spec(@default_pool, opts)
      end

      def pool_size do
        :hackney_pool.count(@default_pool)
      end

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
            Logger.debug "\t[HIT] #{url}"
            {:ok, value}
          {:missing, nil} ->
            Logger.debug "\t[MISS] \#{url}"
            url
            |> get(%{all_options | cache_options: %{skip: true}})
            |> handle_cache(url, cache_options)
        end
      end
      def get(url, %{} = incomplete_options) do
        options = @default_options |> Map.merge(incomplete_options)
        skip_option_undefined = is_nil(incomplete_options[:cache_options]) || Enum.empty?(incomplete_options[:cache_options])
        options = if skip_option_undefined, do: Map.put(options, :cache_options, %{skip: true}), else: options
        url
        |> get(options)
      end

      def clear_cache(url) do
        Cachex.del(:content_gateway_cache, url)
        Cachex.del(:content_gateway_cache, "stale:#{url}")
      end

      @lint {Credo.Check.Readability.MaxLineLength, false}
      defp request(url, headers, options) do
        merged_headers = headers |> merge_request_headers
        merged_options = options |> merge_request_options
        response = url |> HTTPoison.get(merged_headers, merged_options)
        case response do
          {:ok, %HTTPoison.Response{status_code: 200, body: body}} -> {:ok, body}
          {:ok, %HTTPoison.Response{status_code: 400}} -> as_error :bad_request
          {:ok, %HTTPoison.Response{status_code: 401}} -> as_error :unauthorized
          {:ok, %HTTPoison.Response{status_code: 403}} -> as_error :forbidden
          {:ok, %HTTPoison.Response{status_code: 404}} -> as_error :not_found
          {:ok, %HTTPoison.Response{status_code: status}} -> status |> as_custom_error(url)
          {:error, %HTTPoison.Error{reason: reason}} -> reason |> as_custom_error(url)
        end
      end

      defp as_error(description), do: {:error, {description, <<>>}}
      defp as_custom_error(reason, url), do: {:error, "Request failed [url: #{url}] [reason: #{reason}]"}

      defp merge_request_headers(headers) do
        headers
        |> Map.merge(%{"User-Agent" => user_agent()})
      end
      defp merge_request_options(options) do
        initial_options = %{
          timeout: connection_timeout(),
          recv_timeout: request_timeout(),
          hackney: [pool: @default_pool]
        }

        initial_options
        |> Map.merge(options)
        |> Map.to_list
      end

      defp report_http_error({:error, {:bad_request, body}} = result, url) do
        Logger.info "Bad Request [url:#{url}]"
        {:error, :bad_request}
      end
      defp report_http_error({:error, {:unauthorized, body}} = result, url) do
        Logger.info "Unauthorized [url:#{url}]"
        {:error, :unauthorized}
      end
      defp report_http_error({:error, {:forbidden, body}} = result, url) do
        Logger.info "Forbidden [url:#{url}]"
        {:error, :forbidden}
      end
      defp report_http_error({:error, {:not_found, body}} = result, url) do
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
      defp handle_cache({:error, :bad_request}, key), do: {:error, :bad_request}
      defp handle_cache({:error, :unauthorized}, key), do: {:error, :unauthorized}
      defp handle_cache({:error, :forbidden}, key), do: {:error, :forbidden}
      defp handle_cache({:error, :not_found}, key), do: {:error, :not_found}
      defp handle_cache({:error, message} = err, key, _), do: handle_cache(err, key)
      defp handle_cache({:error, message} = result, key) do
        case Cachex.get(:content_gateway_cache, "stale:#{key}") do
          {:ok, value} ->
            Logger.debug "[STALE] #{key}"
            {:ok, value}
          {:missing, nil} ->
            Logger.warn message
            {:error, :no_stale}
        end
      end
      defp handle_cache_for_4xx(error_4xx), do: {:error}

      defp to_ok_tuple(value), do: {:ok, value}

      defp store_on_cache(data, key, expires_in, nil), do: store_on_cache(data, key, expires_in)
      defp store_on_cache(data, key, nil, nil), do: store_on_cache(data, key)
      defp store_on_cache(data, key, expires_in, stale_expires_in) do
        data
        |> store_on_cachex(key, expires_in)
        |> store_on_cachex("stale:#{key}", stale_expires_in)
      end
      defp store_on_cache(data, key, nil), do: store_on_cache(data, key)
      defp store_on_cache(data, key, expires_in), do: store_on_cachex(data, key, expires_in)
      defp store_on_cache(data, key), do: store_on_cachex(data, key)

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
