defmodule ContentGateway.Example do
  use ContentGateway

  def connection_timeout do
    2_000
  end

  def request_timeout do
    1_000
  end

  def user_agent do
    "Elixir (Example)"
  end

end
