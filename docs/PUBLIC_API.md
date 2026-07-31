# Spectre Lens public API — 0.1.6 baseline

This file is the normative public API manifest for the recoverable `0.1.6`
baseline. Compatibility guarantees apply only to the modules and callables
listed below. Any module, function, macro, or callback not listed here is an
implementation detail even when it is exported or visible in generated docs.

Default arguments are expanded into every callable arity. For the listed
modules, documented types, opaque types, and documented struct fields are also
public. Modules with no callable row expose only their documented module,
type, and struct contract.

## Manifest

- `Mix.Tasks.Spectre.Lens.Doctor`
- `Mix.Tasks.Spectre.Lens.Install`
- `Spectre.Lens`
  - functions: `config/1`, `runtime/1`, `runtime/2`
- `Spectre.Lens.ActionProvider`
- `SpectreLens`
  - functions: `act/2`, `act/3`, `agent_context/1`, `agent_context/2`, `cdp/2`, `cdp/3`, `cdp/4`, `close/1`, `close_tab/1`, `command/2`, `command/3`, `command/4`, `delete_session/2`, `discover/1`, `discover/2`, `doctor/0`, `doctor/1`, `explain_error/1`, `export/2`, `export/3`, `export_session/2`, `get_session/2`, `import_session/3`, `llms/1`, `llms/2`, `llms_context/1`, `llms_context/2`, `look/1`, `look/2`, `new_tab/1`, `new_tab/2`, `open/0`, `open/1`, `outline/1`, `outline/2`, `put_session/3`, `resolve_tab/2`, `runtime_info/1`, `save_session/1`, `save_session/2`, `save_session/3`, `stop_watch/1`, `unfocus/1`, `unfocus/2`, `version/0`, `watch/1`, `watch/2`, `zoom_in/2`, `zoom_in/3`, `zoom_out/1`, `zoom_out/2`
- `SpectreLens.ActionRef`
- `SpectreLens.ActionResolver`
  - functions: `clickable_ref/3`, `navigation_url/3`
- `SpectreLens.Browser`
  - functions: `doctor/2`, `protocol/2`, `resolve/1`, `validate/1`
  - callbacks: `default_protocol/0`, `doctor/1`, `handle_info/2`, `max_tabs/2`, `start_instance/2`, `stop_instance/1`
- `SpectreLens.Browser.Adapter`
- `SpectreLens.Browser.Instance`
- `SpectreLens.Browsers.Lightpanda`
- `SpectreLens.Browsers.RemoteCDP`
- `SpectreLens.CDP.Connection`
  - functions: `await_event/1`, `await_event/2`, `cancel_event_waiter/1`, `close/1`, `open/1`, `register_event_waiter/2`, `register_event_waiter/3`, `send_command/2`, `send_command/3`, `send_command/4`, `send_command/5`, `subscribe_event/2`, `subscribe_event/3`, `subscribe_event/4`, `unsubscribe_event/2`, `unsubscribe_event/3`, `unsubscribe_event/4`, `wait_for_event/2`, `wait_for_event/3`, `wait_for_event/4`
- `SpectreLens.CDPError`
  - functions: `new/2`, `new/3`
- `SpectreLens.CaughtError`
  - functions: `new/3`, `new/4`
- `SpectreLens.ConnectionError`
  - functions: `new/1`
- `SpectreLens.Context`
- `SpectreLens.Discovery`
- `SpectreLens.Discovery.Candidate`
- `SpectreLens.Discovery.DeterministicScorer`
- `SpectreLens.Discovery.Page`
- `SpectreLens.Discovery.Scorer`
  - callbacks: `rank_candidates/3`, `score_candidate/3`
- `SpectreLens.ElementNotFoundError`
  - functions: `new/1`
- `SpectreLens.Errors`
  - functions: `hint/1`, `retryable?/1`, `safe/2`, `to_agent/1`
- `SpectreLens.JavaScriptError`
  - functions: `new/1`
- `SpectreLens.Lightpanda`
  - functions: `compatible_version?/1`, `default_path/0`, `detect/0`, `detect/1`, `doctor/0`, `doctor/1`, `ensure/0`, `ensure/1`, `free_port/0`, `install/0`, `install/1`, `install_url/0`, `install_url/1`, `minimum_version/0`, `release_asset/0`, `release_asset/1`, `start_instance/0`, `start_instance/1`, `stop_instance/1`, `version/0`, `version/1`
- `SpectreLens.LlmsTxt`
  - functions: `candidate_urls/1`, `discover/1`, `discover/2`, `discover_from_page/2`, `discover_from_page/3`, `parse/1`, `parse/2`, `to_context/1`, `to_context/2`
- `SpectreLens.MapHelpers`
  - functions: `blank?/1`, `get/2`, `get/3`, `known_atom_key/1`, `link?/1`
- `SpectreLens.Outline`
  - functions: `from_regions/2`, `page_map_opts/1`
- `SpectreLens.Outline.Section`
- `SpectreLens.Page`
  - functions: `click/2`, `click/3`, `close/1`, `command/2`, `command/3`, `command/4`, `evaluate/2`, `evaluate/3`, `fill/3`, `fill/4`, `focus/2`, `focus/3`, `forms/1`, `forms/2`, `html/1`, `html/2`, `interactive_elements/1`, `interactive_elements/2`, `links/1`, `links/2`, `markdown/1`, `markdown/2`, `navigate/2`, `navigate/3`, `new/1`, `new/2`, `page_map/1`, `page_map/2`, `pdf/1`, `pdf/2`, `restore_session/2`, `restore_session/3`, `screenshot/1`, `screenshot/2`, `scroll/1`, `scroll/2`, `semantic_tree/1`, `semantic_tree/2`, `session_snapshot/1`, `session_snapshot/2`, `structured_data/1`, `structured_data/2`, `submit/2`, `submit/3`, `submit/4`, `title/1`, `url/1`, `wait_for_navigation/2`, `wait_for_navigation/3`, `wait_for_selector/2`, `wait_for_selector/3`
- `SpectreLens.PageMap`
- `SpectreLens.Plug`
  - callbacks: `call/2`
- `SpectreLens.PlugPipeline`
  - functions: `run/1`, `run/2`
- `SpectreLens.Plugs`
  - functions: `default/0`
- `SpectreLens.Plugs.ActionRefs`
  - functions: `build_from_forms/1`, `build_from_interactive/1`, `build_from_links/1`
- `SpectreLens.Plugs.BasicInfo`
- `SpectreLens.Plugs.EmptyViewDiagnostics`
- `SpectreLens.Plugs.Forms`
- `SpectreLens.Plugs.Hash`
- `SpectreLens.Plugs.Helpers`
  - functions: `collect/3`, `included?/2`, `put_error/2`, `put_warning/2`
- `SpectreLens.Plugs.Html`
- `SpectreLens.Plugs.Interactive`
- `SpectreLens.Plugs.Links`
- `SpectreLens.Plugs.LlmsTxt`
- `SpectreLens.Plugs.Markdown`
- `SpectreLens.Plugs.NormalizeMarkdown`
- `SpectreLens.Plugs.SemanticTree`
- `SpectreLens.Plugs.StructuredData`
- `SpectreLens.Protocol`
  - functions: `resolve/1`, `validate/1`
  - callbacks: `capture_session/2`, `click/3`, `close_tab/1`, `command/4`, `evaluate/3`, `fill/4`, `focus/3`, `forms/2`, `handle_info/2`, `handle_tab_closed/1`, `html/2`, `interactive_elements/2`, `links/2`, `markdown/2`, `navigate/3`, `new_tab/2`, `page_map/2`, `pdf/2`, `restore_session/3`, `screenshot/2`, `scroll/2`, `semantic_tree/2`, `structured_data/2`, `submit/4`, `subscribe/2`, `tab_key/1`, `title/1`, `url/1`, `wait_for_navigation/3`, `wait_for_selector/3`
- `SpectreLens.Protocol.Adapter`
- `SpectreLens.Protocol.CDP`
- `SpectreLens.Protocol.Lightpanda`
- `SpectreLens.Region`
- `SpectreLens.Runtime`
  - functions: `child_spec/1`, `close/1`, `delete_session/2`, `export_session/2`, `get_session/2`, `import_session/3`, `info/1`, `new_tab/2`, `put_session/3`, `release_tab/2`, `resolve_tab/2`, `save_session/1`, `save_session/2`, `save_session/3`, `start_link/0`, `start_link/1`
- `SpectreLens.Session`
  - functions: `merge/2`, `new/0`, `new/1`, `normalize/1`, `storage_for_origin/2`, `to_map/1`
- `SpectreLens.Tab`
- `SpectreLens.TabRef`
  - functions: `new/1`
- `SpectreLens.Telemetry`
  - functions: `emit/1`, `emit/2`, `emit/3`, `events/0`, `span/3`, `span_events/0`
- `SpectreLens.TimeoutError`
  - functions: `new/0`, `new/1`
- `SpectreLens.URLPolicy`
  - functions: `authorize/3`, `merge_options/2`, `same_origin?/2`, `sanitize/1`, `take_options/1`, `validate/1`, `validate/2`, `validate_options/1`, `validate_request/1`, `validate_request/2`
- `SpectreLens.UnsupportedError`
  - functions: `new/1`, `new/2`
- `SpectreLens.UntrustedContent`
  - functions: `wrap/1`, `wrap/2`, `wrapped?/1`
- `SpectreLens.View`
- `SpectreLens.Watcher`
  - functions: `start/1`, `start/2`, `stop/1`
