defmodule ContentGateway.Mixfile do
  use Mix.Project

  def project do
    [app: :content_gateway,
     version: "1.1.0",
     elixir: "~> 1.3",
     description: description(),
     package: package(),
     test_coverage: [tool: ExCoveralls],
     deps: deps()]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    [applications: [:logger, :httpoison, :cachex, :poison, :mnesia],
     mod: {ContentGateway.App, []}]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [
      {:poison, "~> 2.0 or ~> 3.0"},
      {:cachex, "~> 1.2.2"},
      {:httpoison, "~> 0.11.1"},
      {:excoveralls, "~> 0.5", only: :test},
      {:credo, "~> 0.4.12", only: [:dev, :test]},
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:fake_server, "~> 0.5.0", only: :test},
      {:mock, "~> 0.2.0", only: :test},
      {:inch_ex, only: :docs},
    ]
  end

  defp description do
        """
    A Gateway to fetch external content for 3rd party services.
        """
  end

  defp package do
    [name: :content_gateway,
     maintainers: ["Emerson Macedo"],
     licenses: ["Apache 2.0"],
     links: %{"GitHub" => "https://github.com/emerleite/content_gateway_elixir"}]
  end
end
