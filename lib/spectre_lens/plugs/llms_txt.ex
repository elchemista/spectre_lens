defmodule SpectreLens.Plugs.LlmsTxt do
  @moduledoc false

  alias SpectreLens.{Context, LlmsTxt, Plug}
  alias SpectreLens.Plugs.Helpers

  @behaviour Plug

  @doc false
  @spec call(Context.t(), keyword()) :: Context.t()
  def call(%Context{} = context, opts) do
    if enabled?(context, opts) do
      discover(context, opts)
    else
      context
    end
  end

  @spec enabled?(Context.t(), keyword()) :: boolean()
  defp enabled?(context, opts) do
    Keyword.get(opts, :llms?, true) or Helpers.included?(context, :llms)
  end

  @spec discover(Context.t(), keyword()) :: Context.t()
  defp discover(%Context{view: %{url: url}} = context, opts) when is_binary(url) do
    case SpectreLens.Protocol.evaluate(context.tab, metadata_script(), opts) do
      {:ok, links} ->
        put_llms(context, url, List.wrap(links), opts)

      {:error, reason} ->
        maybe_record_error(context, reason)
    end
  end

  defp discover(context, _opts), do: context

  @spec put_llms(Context.t(), binary(), [map()], keyword()) :: Context.t()
  defp put_llms(context, url, links, opts) do
    opts = Keyword.put_new(opts, :full?, true)

    case LlmsTxt.discover_from_page(url, links, opts) do
      {:ok, doc} ->
        context
        |> put_in([Access.key(:view), Access.key(:llms)], doc)
        |> put_context(doc, opts)

      {:error, {:llms_txt_not_found, _reason, []}} ->
        context

      {:error, reason} ->
        maybe_record_error(context, reason)
    end
  end

  @spec put_context(Context.t(), LlmsTxt.t(), keyword()) :: Context.t()
  defp put_context(context, doc, opts) do
    case LlmsTxt.to_context(doc, opts) do
      {:ok, content} -> put_in(context.view.llms_context, content)
      {:error, reason} -> Helpers.put_warning(context, {:llms_context, reason})
    end
  end

  @spec maybe_record_error(Context.t(), term()) :: Context.t()
  defp maybe_record_error(context, reason) do
    if Helpers.included?(context, :llms) do
      Helpers.put_error(context, {:llms, reason})
    else
      Helpers.put_warning(context, {:llms, reason})
    end
  end

  @spec metadata_script() :: binary()
  defp metadata_script do
    """
    (() => {
      const head = document.head || document.querySelector('head');
      if (!head) return [];

      const fromLink = Array.from(head.querySelectorAll('link[href]')).map((node) => ({
        source: 'link',
        href: node.href,
        rel: node.getAttribute('rel') || '',
        type: node.getAttribute('type') || '',
        title: node.getAttribute('title') || ''
      }));

      const fromMeta = Array.from(head.querySelectorAll('meta[content]')).map((node) => ({
        source: 'meta',
        href: node.getAttribute('content') || '',
        name: node.getAttribute('name') || '',
        property: node.getAttribute('property') || '',
        itemprop: node.getAttribute('itemprop') || ''
      }));

      return fromLink.concat(fromMeta).filter((entry) => {
        const haystack = Object.values(entry).join(' ').toLowerCase();
        return haystack.includes('llms.txt') ||
          haystack.includes('llms-full.txt') ||
          haystack.includes('llms-ctx-full.txt') ||
          haystack.includes('llms');
      });
    })()
    """
  end
end
