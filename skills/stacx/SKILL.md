---
name: stacx
description: Drive a docker compose project through stacx contexts (`stack/compose`). Use when a project has `stack/compose` or a `stack/context/` submodule and the task runs, builds, inspects or extends a compose stack — selecting a context, running a second instance from a worktree, keeping per-machine config in override tiers, printing the resolved environment, building a release without personal tiers, adding a context or a tier, or finding why a compose command acted on the wrong stack.
---

# stacx — stack contexts for compose

## Overview

[stacx](https://github.com/pr0n1x/stacx) gives one compose project named
**contexts**: variants of the stack (`beta`, `prod`, a pilot beside the main
product, a one-shot certificate job), each resolving to its own compose file,
env file, profiles and project name, plus **declared override tiers** for
per-machine config. One wrapper, `stack/compose`, evaluates the resolver and
forwards everything else to `docker compose` (or podman), so nothing acts on
the wrong stack.

A project that uses it has `stack/compose` (a link into the `stack/context/`
submodule, or the files copied beside it), `compose[.<ctx>].ya?ml` files in
the root, gitignored `context[.<ctx>].env` and `compose[.<ctx>].env` files,
and usually tracked examples of those under `stack/examples/`. The reference
is `stack/context/README.md`; `stack/context/examples/context.example.env`
is the commented copy of every knob.

## The wrapper, and the user's shell

Two ways reach a context, for two kinds of caller.

**An agent always goes through `stack/compose`.** An agent's shell carries
no direnv and keeps no state between commands, so a bare `docker compose`
there acts on the default stack with no tiers — silently, on the wrong
containers. The wrapper resolves compose files, env files, profiles and
project name for the context on every invocation, which is also what a
script or CI wants.

**A person's interactive shell carries the context through direnv.**
`source stack/context/envrc` in `.envrc` exports the active context's
`COMPOSE_*` variables (from an exported `COMPOSE_CONTEXT` or the
`context.env` pin), so plain `docker compose up -d` acts on the active
context. That is the intended workflow, not a mistake: when a user's
command or a project doc says `docker compose`, read it as "the active
context, in a direnv shell". From such a shell the wrapper is how one
reaches *another* context (`stack/compose --cx <other> ps`) or runs the
base stack without the tiers (`--no-override`).

```sh
stack/compose --cx <ctx> up -d
stack/compose --cx <ctx> ps
stack/compose logs -f <service>          # COMPOSE_CONTEXT taken from the environment
stack/compose --env                      # print what this invocation resolves to; runs nothing
stack/compose --no-override --cx <ctx> up -d
eval "$(stack/compose --export)"         # the resolved variables, into this shell
```

| Flag | Effect |
|---|---|
| `--cx <ctx>`, `--ctx`, `--context` (or `=<ctx>`) | select the context; `default` names the default stack explicitly |
| `--no-override` | clear `COMPOSE_CTX_OVERRIDES`: run the base stack alone, with no personal tiers |
| `--env`, `--export` | print the resolved `COMPOSE_*` variables as `export`/`unset` lines and run nothing |

Everything else is passed to compose untouched, in order. `COMPOSE_COMMAND`
swaps the engine (`"podman compose"`, `podman-compose`).

## How a context resolves

All paths are relative to the project root (the directory above
`stack/`). For context `<ctx>`:

| Variable | Value |
|---|---|
| `COMPOSE_FILE` | `compose.<ctx>.ya?ml`, then the override tiers `COMPOSE_CTX_OVERRIDES` declares, left to right |
| `COMPOSE_ENV_FILES` | `compose.<ctx>.env` if present, then the tiers' `.env` files, then `COMPOSE_CTX_ENV_FILES` last |
| `COMPOSE_PROJECT_NAME` | `<base>-<ctx>`; `<base>` is the checkout directory's name unless `COMPOSE_CONTEXT_BASE` renames it |
| `COMPOSE_PROFILES` | `<ctx>`, merged with `COMPOSE_CTX_PROFILES` |

The **default stack** is the empty context: `compose.ya?ml`, `compose.env`,
the bare `<base>`. A named context without a compose file of its own falls
back to it with a stderr note. `default`, `local` and `override` are
reserved names. `docker-compose[.<ctx>].ya?ml` wins over `compose…` when
both exist.

The context comes from, in order: `--cx`, an exported `COMPOSE_CONTEXT`
(direnv), a `COMPOSE_CONTEXT=` line in `context.env`.

### The files

| File | Tracked? | Holds |
|---|---|---|
| `compose[.<ctx>].ya?ml` | yes | the base stack: everything true of it anywhere; **no single-instance config** |
| `compose[.<ctx>].env` | no, per machine | this host's values: subnets, credentials, `IMAGE_TAG`; the server has its own |
| `context.env` | no, per checkout | the checkout's identity: `COMPOSE_CONTEXT_BASE`, `COMPOSE_CONTEXT`; may carry the `COMPOSE_CTX_*` knobs |
| `context.<ctx>.env` | no | the knobs for one context; overrides `context.env` per variable |
| `compose[.<ctx>].local.ya?ml` + `.env` | no | the **local tier**: this machine's identity for the stack — container names, pinned bridge, DNS sidecar, published ports |
| `compose[.<ctx>].override.ya?ml` + `.env` | no | the **override tier**: what must win — a swapped image, a `!reset` service |
| `stack/examples/*` | yes | the copies to start the gitignored files from |

Knobs (`context[.<ctx>].env`, or the environment, which wins per variable):
`COMPOSE_CTX_PROFILES` (profiles beside the context's own),
`COMPOSE_CTX_OVERRIDES` (the tiers, colon-separated stems),
`COMPOSE_CTX_ENV_FILES` (extra env files appended last, the strongest
layer), `COMPOSE_CTX_FORCE_FILES` (name the files even when absent). Values
are literal, never evaluated; comments on their own lines.

### Override tiers

Declared, never discovered: a tier file that no stem names is inert.
`COMPOSE_CTX_OVERRIDES` lists extensionless stems; for each, `<stem>.ya?ml`
joins `COMPOSE_FILE` and `<stem>.env` joins `COMPOSE_ENV_FILES`. Placeholders
keep one declaration portable: `%compose` is the base file's stem,
`%context` the context name, and `.%context` drops its dot for the default
context — so `%compose.%context.local` is `compose.beta.local` under `beta`
and `compose.local` for the default stack. Compose merges left to right,
last wins, so declare the local tier first and the override tier after it:
`%compose.%context.local:%compose.%context.override`.

## Use cases

**Run the stack in the active context.** With direnv (`source
stack/context/envrc` in `.envrc`) or a `context.env` pin, the shell already
carries the context: `stack/compose up -d`. From any other shell, or for
another context, name it: `stack/compose --cx <ctx> up -d`.

**See what a command would act on before running it.** `stack/compose --cx
<ctx> --env` prints the resolved `COMPOSE_FILE`, `COMPOSE_ENV_FILES`,
`COMPOSE_PROJECT_NAME` and `COMPOSE_PROFILES`. Read it whenever a container
is missing, a variable looks wrong, or two stacks seem to collide.

**Run a second instance beside the first — a git worktree.** The worktree's
directory name gives it its own `<base>`, so project names, volumes and
networks already differ. What would still collide is daemon-global config
in a tier (fixed `container_name`, a pinned subnet, a DNS address), so run
the base stack alone: `stack/compose --no-override --cx <ctx> up -d`. A
fresh worktree needs the submodule first: `git submodule update --init --
stack/context`.

**Decide where a piece of config belongs.** Anything true of the stack
everywhere goes in the base file. Anything that is this machine's identity
— names, the bridge, the sidecar, published host ports — goes in the local
tier. Anything that must win over both — a swapped image, a service
`!reset` — goes in the override tier. Credentials, subnets and the image
tag go in `compose[.<ctx>].env`, which is per machine: deploying ships the
compose files and edits each host's env file in place; copying one host's
over another's replaces that host's configuration.

**Build a release.** Pass the tag explicitly and skip the personal tiers:

```sh
IMAGE_TAG=<version> stack/compose --cx <ctx> --no-override --profile all build --push
```

Both halves matter. The checkout's env file usually pins a local tag
(`IMAGE_TAG=local`), so an implicit build would tag and push that; a shell
variable outranks the env file. And `--no-override` keeps the local tier
out, which may swap in a host-binary dockerfile or rename the images.

**Resolve containers by label, not by name.** Container names come from a
tier that may be absent, so scripts use the wrapper
(`stack/compose --cx <ctx> ps -q <service>`) or docker's labels:
`docker ps --filter label=com.docker.compose.project=<project> --filter
label=com.docker.compose.service=<service>`.

**Add a context.** Create `compose.<ctx>.ya?ml` (and, if the host needs
values, `compose.<ctx>.env` with a tracked `stack/examples/` copy); the
context's profile is its own name, so services gated on `profiles: [<ctx>]`
start with it. Add a `context.<ctx>.env` example if the context needs its
own tiers or profiles. The bash completion picks the new name up from the
files that exist.

**Add a tier.** Write `compose[.<ctx>].<tier>.ya?ml`, add the
`stack/examples/` copy, and declare its stem in `COMPOSE_CTX_OVERRIDES` —
nothing happens until the stem is declared. Keep `.gitignore` covering
`*.env`, `!*.example.env`, `/compose[.*].local.y*ml` and
`/compose[.*].override.y*ml`.

**Run a one-shot job as its own context.** A job that shares no network and
no lifecycle with the stacks (certificate issuance, a backup) is cleanest
as a context of its own: `compose.<job>.yml`, run with
`stack/compose --cx <job> up --abort-on-container-exit --exit-code-from
<service>` and torn down after. A `run --rm` container is registered under
no service name, so anything that must reach the job by name needs `up`.

**Shell comfort.** `source stack/context/completion.bash` completes `--cx`
with the project's contexts and services with the context's files, and
defines `dok`: `stack/compose` where one exists, `docker compose`
elsewhere. direnv is optional; the `context.env` files carry the same
configuration for shells without it, and `--cx`, `--no-override` and any
exported variable still win over them.

## Pitfalls

- A command that "did nothing" or acted on the wrong containers ran bare
  `docker compose` in a shell without direnv (an agent's, a script, CI), or
  in a shell whose `COMPOSE_CONTEXT` differs from the intended one. Re-run
  with `--cx` and check `--env`.
- A tier that "has no effect" is not declared in `COMPOSE_CTX_OVERRIDES`,
  or its stem does not match the file (`compose.beta.local` vs
  `compose.local`). The resolver notes a skipped stem on stderr.
- Single-instance config in a base file (`container_name`, a pinned subnet,
  a DNS server's address) stops a second checkout from running the stack.
  Move it to the local tier.
- An implicit image tag builds and pushes whatever the env file pins. Pass
  `IMAGE_TAG` on the command line for releases.
- A `git worktree` does not initialise submodules: `stack/compose` is a
  dangling link until `git submodule update --init -- stack/context`.
- The resolver is re-evaluated on every direnv prompt and recognises its
  own earlier output, so exporting a `COMPOSE_*` variable by hand on top
  of it is what breaks the cycle — prefer `--cx`.

## Reference

- The stacx README (`stack/context/README.md` where a project vendors it as
  a submodule; this skill ships beside it as `skills/stacx/`) — install,
  usage, resolution, knobs, tiers, re-eval safety.
- `examples/context.example.env` in the same checkout — every knob,
  commented.
- A project's own doc for how it uses the contexts (which contexts exist,
  which tiers, which zones): look for it next to the compose files or under
  `docs/`.
