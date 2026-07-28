defmodule SpectreLens.StackContractStack do
  @moduledoc false

  use Spectre.Stack, id: :lens_contract

  install Spectre.Lens, trust: :untrusted do
    backend(SpectreLens.Protocol.LightpandaCDP,
      instances: 2,
      network_policy: :public
    )

    policy(SpectreLens.URLPolicy)
  end
end
