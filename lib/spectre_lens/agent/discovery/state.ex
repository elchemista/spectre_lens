defmodule SpectreLens.Discovery.State do
  @moduledoc false

  alias SpectreLens.Discovery.{Candidate, Page}
  alias SpectreLens.Tab

  @type origin :: {binary() | nil, binary() | nil, integer() | nil}

  @type t :: %__MODULE__{
          tab: Tab.t(),
          goal: binary(),
          root_url: binary(),
          origin: origin(),
          scorer: module(),
          scorer_opts: keyword(),
          opts: keyword(),
          queue: :queue.queue({binary(), non_neg_integer()}),
          seen: MapSet.t(binary()),
          current_url: binary(),
          visited: [Page.t()],
          visited_count: non_neg_integer(),
          candidates: [Candidate.t()],
          forms: [map()],
          warnings: [term()],
          errors: [term()]
        }

  @enforce_keys [
    :tab,
    :goal,
    :root_url,
    :origin,
    :scorer,
    :scorer_opts,
    :opts,
    :queue,
    :seen,
    :current_url
  ]
  defstruct [
    :tab,
    :goal,
    :root_url,
    :origin,
    :scorer,
    :scorer_opts,
    :opts,
    :queue,
    :seen,
    :current_url,
    visited: [],
    visited_count: 0,
    candidates: [],
    forms: [],
    warnings: [],
    errors: []
  ]
end
