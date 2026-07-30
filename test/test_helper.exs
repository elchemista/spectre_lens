unless System.get_env("SPECTRE_LENS_INTEGRATION") == "1" do
  ExUnit.configure(exclude: [:integration])
end

Code.require_file("support/stack_contract_agents.exs", __DIR__)

ExUnit.start()
