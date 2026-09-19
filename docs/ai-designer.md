# AI Designer prototype

The left-side AI Designer panel can use an existing local Codex CLI or Claude CLI login. The command-line process runs
on the Mac, but model inference is not offline: prompts, recent chat text, and the current canvas/layer metadata are sent
to the selected provider's model service. Image pixels are not included in this prototype.

## Supported actions

- create a canvas when no canvas exists
- add editable rectangle, rounded-rectangle, and ellipse shape layers
- rename, duplicate, move, resize, and rotate a layer by stable UUID
- change layer opacity and visibility
- apply a multi-action plan as one undoable edit

The model returns a JSON-Schema-constrained plan. The app validates every action and executes only the allowlisted editor
commands. It does not grant the model shell, arbitrary file, network, painting, deletion, or project-replacement access.

## Local requirements

The prototype looks for `codex` or `claude` in `/opt/homebrew/bin`, `/usr/local/bin`, or `~/.local/bin`. The selected CLI
must already be authenticated. Codex is launched in an empty temporary directory with a read-only sandbox; Claude is
launched in restricted safe mode with tools disabled. Temporary schemas and responses are deleted after each turn.

## Current limitations

- generated raster images, editable text layers, and arbitrary vector paths are not implemented yet
- each turn starts an ephemeral CLI request rather than a persistent app-server conversation
- provider cancellation terminates the current child process, but is global to the app prototype
- a production sandboxed build should move local-agent execution into a separately signed companion or connect to a
  user-started local Codex app-server instead of relying on direct CLI process launch
