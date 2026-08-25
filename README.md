# stacx — stack contexts for compose

A small bash toolkit that gives a compose project **contexts**: named
variants of one stack (`beta`, `prod`, `staging`, …), each resolving to its
own compose file, env file, profiles and project name, plus declared
override tiers for per-machine config. A context is selected by a flag, by
direnv, or by a pinned file — and every invocation goes through one wrapper,
so nothing ever acts on the wrong stack. Works with `docker compose` and
with podman.

| File | Role |
|---|---|
| `compose` | The wrapper: `stack/compose [--cx <ctx>] [--no-override] <compose args…>` |
| `export.env.sh` | The resolver: computes the `COMPOSE_*` environment for a context |
| `envrc` | direnv fragment — the shell carries the active context's environment |
| `completion.bash` | Bash completion for the wrapper, plus the `dok` shorthand |
| `examples/context.example.env` | Commented copy of the `context[.<ctx>].env` knobs |

## Install

Vendor it as a submodule under the directory that holds the project's
dockerfiles, provisioning files and so on — `stack/` by convention — and
link the wrapper beside it:

```sh
git submodule add git@github.com:pr0n1x/stacx.git stack/context
ln -s context/compose stack/compose
git add stack/compose
```

The wrapper takes the **project root to be the directory above its own
place** (`stack/compose` → the root) and finds the resolver beside its real
file (`stack/context/`). So the directory name is free, but the link is what
ties the two together: call `stack/compose`, never the file inside the
checkout.

A fresh clone needs the submodule: `git clone --recurse-submodules …`, or
`git submodule update --init` afterwards — the same in a `git worktree`,
which does not initialise submodules on its own. Updating:
`git submodule update --remote stack/context`.

Without a submodule, copying the files straight into `stack/` works too —
the wrapper and the resolver are then siblings, as before.

## Usage

```sh
stack/compose --cx beta up -d
stack/compose --cx beta ps
stack/compose logs -f postgres        # COMPOSE_CONTEXT taken from the environment
stack/compose --env                   # print what this invocation resolves to
stack/compose --no-override --cx beta up -d
eval "$(stack/compose --export)"      # the resolved variables, into this shell
```

| Flag | Effect |
|---|---|
| `--cx <ctx>`, `--ctx`, `--context` (or `=<ctx>`) | select the context; `default` names the default stack explicitly |
| `--no-override` | clear `COMPOSE_CTX_OVERRIDES` — run the base stack alone (a second instance beside the first) |
| `--env` | print the resolved `COMPOSE_*` variables and run nothing |
| `--export` | print the resolver's `export`/`unset` lines for `eval` and run nothing |

Everything else is passed to compose untouched, in order. The command it
runs is `docker compose` unless `COMPOSE_COMMAND` says otherwise
(`COMPOSE_COMMAND="podman compose"`, `COMPOSE_COMMAND=podman-compose`).

### direnv

```sh
# .envrc
source stack/context/envrc
```

The shell then carries the `COMPOSE_*` environment of the active context —
a `COMPOSE_CONTEXT` exported above that line, or the `context.env` pin —
and plain `docker compose` commands act on it. The wrapper stays the safe
way to reach *another* context from that shell.

### Completion

```sh
# ~/.bashrc
source /path/to/project/stack/context/completion.bash
```

Completes `--cx` with the contexts the project actually defines, delegates
everything else to docker's own completion (with the context's compose
files exported, so service names are the right stack's), and defines `dok`:
`stack/compose` when the working directory has one, `docker compose`
elsewhere.

## How a context resolves

All paths are relative to the project root. Both compose-spec spellings are
accepted — an existing `docker-compose[.<ctx>].ya?ml` wins over
`compose[.<ctx>].ya?ml`, and the `.env` files follow whichever stem matched.

For context `<ctx>`:

| Variable | Value |
|---|---|
| `COMPOSE_FILE` | `compose.<ctx>.ya?ml`, plus the override tiers `COMPOSE_CTX_OVERRIDES` declares |
| `COMPOSE_ENV_FILES` | `compose.<ctx>.env` if present, plus the tiers' `.env` files, plus `COMPOSE_CTX_ENV_FILES` last |
| `COMPOSE_PROJECT_NAME` | `<base>-<ctx>`, where `<base>` is the checkout directory's name unless `COMPOSE_CONTEXT_BASE` renames it |
| `COMPOSE_PROFILES` | `<ctx>`, merged into `COMPOSE_CTX_PROFILES` |

The **default stack** is the empty context: `compose.ya?ml`, `compose.env`,
the bare `<base>`, `COMPOSE_CTX_PROFILES` alone. A named context without a
compose file of its own falls back to it (with a note on stderr, unless the
name is the base file's own `name:`), and the reserved name `default`
selects it explicitly. `local` and `override` are reserved too — they name
override files, not contexts.

The context comes from, in order of precedence: the wrapper's `--cx`, an
exported `COMPOSE_CONTEXT` (direnv), a `COMPOSE_CONTEXT=` line in
`context.env`.

### `context.env` and `context.<ctx>.env`

Gitignored, per-checkout files in the project root
([examples/context.example.env](./examples/context.example.env) is a
commented copy). `context.env` is the checkout's identity
(`COMPOSE_CONTEXT_BASE`, `COMPOSE_CONTEXT`); the `COMPOSE_CTX_*` knobs can
live in either, `context.<ctx>.env` overriding `context.env`, and the
environment overriding both — per variable, with set-but-empty counting as
set. Values are taken literally, never evaluated.

| Knob | Meaning |
|---|---|
| `COMPOSE_CTX_PROFILES` | profiles to enable besides the context's own |
| `COMPOSE_CTX_OVERRIDES` | the override tiers, colon-separated stems (below) |
| `COMPOSE_CTX_ENV_FILES` | extra env files appended last — the strongest layer |
| `COMPOSE_CTX_FORCE_FILES` | name the context's files even when none exist on disk |

### Override tiers

Declared, never discovered: `COMPOSE_CTX_OVERRIDES` names every extra
file as an extensionless stem — `<stem>.ya?ml` joins `COMPOSE_FILE`,
`<stem>.env` joins `COMPOSE_ENV_FILES`, so one tier can carry compose
config, redeclared variables, or both. Placeholders keep one declaration
portable across contexts: `%compose` is the base file's stem, `%context`
the context name, and `.%context` drops its dot for the default context —
so `%compose.%context.local` names `compose.beta.local` under `beta` and
`compose.local` for the default stack. A tier matching nothing is skipped
with a stderr note.

This is where daemon-global config belongs — fixed container names, a
pinned subnet, a DNS server's address — never in a base file, so that a
second checkout (a worktree) can run the same stack with
`stack/compose --no-override --cx <ctx> up -d`.

A `.gitignore` to match:

```gitignore
*.env
!*.example.env
/compose.local.y*ml
/compose.*.local.y*ml
/compose.override.y*ml
/compose.*.override.y*ml
```

## Re-eval safety

The resolver's output is eval'd into the same shell again and again
(direnv: every prompt), so one eval's exports come back as the next one's
input. Every step recognises values it could itself have produced and
rebuilds them from scratch instead of compounding them.

## License

MIT — see [LICENSE](./LICENSE).
