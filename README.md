# ContentGateway

A Gateway to fetch external content for 3rd party services.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed as:

  1. Add `content_gateway` to your list of dependencies in `mix.exs`:

    ```elixir
    def deps do
      [{:content_gateway, "~> 0.1.0"}]
    end
    ```

  2. Ensure `content_gateway` is started before your application:

    ```elixir
    def application do
      [applications: [:content_gateway]]
    end
    ```

