unless System.get_env("SPECTRE_LENS_INTEGRATION") == "1" do
  ExUnit.configure(exclude: [:integration])
end

ExUnit.start()
