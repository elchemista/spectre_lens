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

defmodule SpectreLens.StackContractAgent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreLens.StackContractStack
end

defmodule SpectreLens.NoStackContractAgent do
  @moduledoc false

  use Spectre.Agent
end
