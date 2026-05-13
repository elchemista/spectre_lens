defmodule SpectreLens.Discovery.Scorer do
  @moduledoc """
  Behaviour for goal-scoped discovery scoring.

  Implement this behaviour to plug in an LLM or domain-specific ranker without
  changing Spectre Lens core discovery APIs.
  """

  alias SpectreLens.Discovery.Candidate

  @callback score_candidate(Candidate.t(), map(), keyword()) ::
              {:ok, Candidate.t()} | {:skip, term()} | {:error, term()}

  @callback rank_candidates([Candidate.t()], map(), keyword()) :: {:ok, [Candidate.t()]}
end
