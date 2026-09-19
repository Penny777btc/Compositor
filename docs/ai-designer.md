# AI Designer development build

The left-side AI Designer panel reuses an authenticated local Codex CLI or Claude CLI. The command process runs on the
Mac, but model inference is not offline: the prompt, recent conversation, current canvas/layer metadata, and any
explicitly attached reference image are sent to the selected provider. Codex uses a persistent app-server process and
thread when available, with the restricted one-shot CLI path as a fallback.

## Supported actions

- create a transparent canvas
- add editable rectangle, rounded-rectangle, and ellipse shape layers
- add and edit native editable text layers
- add and edit smooth linear or radial gradient layers with two to twelve color stops
- rename, duplicate, move, resize, rotate, reorder, and group layers by stable UUID
- change layer opacity and visibility
- add default editable adjustment layers and reveal-all/hide-all raster masks
- export multiple named sizes as both PNG and editable `.comp` projects
- preview and confirm a structured multi-action plan before applying it as one undoable edit

The model returns a JSON-Schema-constrained plan. The app validates every action and executes only the allowlisted editor
commands. It does not grant arbitrary shell, file, network, painting, deletion, or project-replacement access.

## Capability contract

The prompt describes exact semantics and limitations for every command. It explicitly forbids approximating unsupported
effects by stacking unrelated shapes. Continuous color transitions must use one `add_gradient` action; the executor also
rejects the legacy pattern of eight or more full-canvas color bands. `no_action` cannot be mixed with mutations.

Canvas and layer metadata is labelled as untrusted document data. The context reports only live editable identities, so
a text, shape, or gradient whose pixels were altered is correctly exposed as a raster image. Adjustment creation is
described as default settings and insertion position, not as an exact per-layer numeric correction. Mask creation is
described as an empty reveal/hide mask, not semantic subject masking.

## Local requirements

The build looks for `codex` or `claude` in `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin`. The selected CLI must
already be authenticated. Codex app-server uses JSON-RPC with a schema-constrained result. The fallback runs in an empty
temporary directory with a read-only sandbox; Claude runs in restricted safe mode. Reference-image access is limited to
the file the user selected.

## Current limitations

- reference images can guide the planning model, but generated raster images are not implemented without a separate
  image-generation provider
- adjustment commands create editable defaults; exact numerical exposure, levels, curves, grain, and gradient-map
  parameters still require their existing editor panels
- arbitrary vector paths, strokes, shadows, semantic masks, painting, and deletion are not exposed to AI yet
- a production sandboxed release still needs a separately signed local AI bridge instead of launching CLIs directly
