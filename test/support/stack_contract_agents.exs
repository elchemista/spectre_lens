defmodule SpectreLens.StackContractAgent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreLens.StackContractStack
end

defmodule SpectreLens.NoStackContractAgent do
  @moduledoc false

  use Spectre.Agent
end
