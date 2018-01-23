# ContentGateway

[![Build Status](https://travis-ci.org/emerleite/content-gateway-elixir.svg?branch=master)](https://travis-ci.org/emerleite/content-gateway-elixir)
[![Coverage Status](https://coveralls.io/repos/github/emerleite/content-gateway-elixir/badge.svg?branch=master)](https://coveralls.io/github/emerleite/content-gateway-elixir?branch=master)

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

