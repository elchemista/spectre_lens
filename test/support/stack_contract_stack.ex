defmodule SpectreLens.StackContractStack do
  @moduledoc false

  use Spectre.Stack, id: :lens_contract

  install Spectre.Lens, trust: :untrusted do
    backend(SpectreLens.Browsers.Lightpanda,
      instances: 2,
      network_policy: :public,
      protocol: SpectreLens.Protocol.Lightpanda
    )

    policy(SpectreLens.URLPolicy)
  end
end
