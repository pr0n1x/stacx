#!/bin/bash

# Computes the COMPOSE_* environment for a project checkout. The output
# is eval'd — by direnv (`envrc`), by the `compose` wrapper per
# invocation, or directly: eval "$(stack/compose --export)".
# https://docs.docker.com/compose/how-tos/environment-variables/envvars/
#
# A CONTEXT is a named variant of the stack (`beta`, `prod`, …),
# selected by the wrapper's `--cx <ctx>`, an exported COMPOSE_CONTEXT
# (direnv), or a COMPOSE_CONTEXT= line in `context.env`. For context
# <ctx> the script exports:
#
#   COMPOSE_FILE          [docker-]compose.<ctx>.ya?ml, plus the
#                         override tiers COMPOSE_CTX_OVERRIDES declares
#   COMPOSE_ENV_FILES     <stem>.<ctx>.env if present, plus the tiers'
#                         .env files, plus COMPOSE_CTX_ENV_FILES last
#   COMPOSE_PROJECT_NAME  <base>-<ctx>, where <base> is the checkout
#                         directory's name unless COMPOSE_CONTEXT_BASE
#                         renames it
#   COMPOSE_PROFILES      <ctx>, merged into COMPOSE_CTX_PROFILES
#
# The DEFAULT stack is the empty context: [docker-]compose.ya?ml,
# <stem>.env, the bare <base>, COMPOSE_CTX_PROFILES alone. A named
# context without a compose file of its own falls back to it, and the
# reserved name `default` selects it explicitly — the escape when a
# `context.env` pin would otherwise choose, or when base = context: a
# `compose.<base>.ya?ml` exists, so the stack's own name resolves as a
# real context instead of the default stack.
#
# The COMPOSE_CTX_* knobs arrive from the environment or from
# `context[.<ctx>].env` (examples/context.example.env is a commented
# copy); the
# environment wins, per variable.
#
# RE-EVAL SAFETY: the output is eval'd into the same shell again and
# again (direnv: every prompt), so last eval's exports come back as
# this eval's input. Every step below therefore recognizes values it
# could itself have produced and rebuilds them from scratch instead of
# compounding them.
#
# The project root is the single argument — always passed explicitly,
# because this script's own location says nothing reliable about it: a
# copy sits one level below the root, the stacx checkout two. The
# wrapper passes the directory above its own place, the direnv fragment
# the directory direnv runs in.
if [ -z "${1-}" ]; then
  echo "usage: $0 <project-dir>   (or: stack/compose --export)" >&2
  exit 2
fi
project_dir="$(cd "$1" && pwd)" || exit 2
project_dir_name="$(basename "$project_dir")"

# Every path below is resolved against the project directory, never the
# caller's CWD: from a subdirectory the existence tests would otherwise
# all miss and compose would fall back to its own upward search —
# quietly configuring the default stack under the context's project
# name.
anchor() { # <list> <separator> -> the list with relative entries anchored
  list="$1"
  sep="$2"
  out=""
  old_ifs="$IFS"
  IFS="$sep"
  for item in $list; do
    case "$item" in
    /*) ;;
    *) item="$project_dir/$item" ;;
    esac
    if [ "$out" = "" ]; then out="$item"; else out="${out}${sep}${item}"; fi
  done
  IFS="$old_ifs"
  printf '%s' "$out"
}

# Both compose-spec spellings are accepted: an existing
# `docker-compose[.<ctx>].ya?ml` wins over the canonical
# `compose[.<ctx>].ya?ml` (also what COMPOSE_CTX_FORCE_FILES invents
# when nothing is on disk), and the `.env` files follow the stem of
# whichever matched.
find_yml() { # <stem> -> "<stem>.yml" or "<stem>.yaml", whichever exists
  if [ -f "$project_dir/$1.yml" ]; then
    printf '%s' "$1.yml"
  elif [ -f "$project_dir/$1.yaml" ]; then
    printf '%s' "$1.yaml"
  fi
}

COMPOSE_ENV_FILES=""
COMPOSE_FILE=""

# What may name a context, wherever one arrives from (environment or
# context.env). Deliberately narrow: the name lands in file paths, the
# compose project name and eval'd shell output.
context_name_re='^[a-z0-9-]+$'

# COMPOSE_CONTEXT determines everything computed below, so it has to
# be settled before anything else. If the environment brought no value
# (no `--cx`, no direnv export), the checkout's `context.env` may pin
# one with a COMPOSE_CONTEXT= line — how a deployment without direnv
# selects its context with no environment at all. The environment
# always wins over the file. The value is validated before use because
# it ends up inside eval'd shell output.
if [ "$COMPOSE_CONTEXT" = "" ] && [ -f "$project_dir/context.env" ]; then
  file_context="$(sed -n 's/^[[:space:]]*COMPOSE_CONTEXT=//p' "$project_dir/context.env" \
                  | head -n1 | tr -d "[:space:]\"'")"
  if [ "$file_context" != "" ]; then
    if echo "$file_context" | grep -Eq "$context_name_re"; then
      COMPOSE_CONTEXT="$file_context"
    else
      echo "context.env ignored: '$file_context' is not a context name" >&2
    fi
  fi
fi

# Reserved context names, settled from either source above.
#
# `default` selects the default stack explicitly. The empty string
# cannot spell that: the wrapper rejects an empty --cx, and an empty
# environment value is what lets the context.env pin apply — so a word
# has to. Cleared here, after the pin, it overrides one.
#
# `local`/`override` name override files, and an override file's name
# can collide with a context's: `--cx local` on a checkout carrying
# `compose.local.yml` would resolve that override file as the base
# file of a context named `local` — a near-empty stack under a new
# project name. Only these two words are known; an override file named
# like a context collides the same way.
case "$COMPOSE_CONTEXT" in
default)
  COMPOSE_CONTEXT=""
  ;;
local | override)
  echo "context '${COMPOSE_CONTEXT}' ignored: '${COMPOSE_CONTEXT}' names override files, not a context — using the default stack" >&2
  COMPOSE_CONTEXT=""
  ;;
esac

# The <base> of every project name below is settled up front the same
# way: from the environment or, failing that, the root `context.env`.
# Only the root file, because the base is a per-checkout identity, not
# a per-context knob — a context file renaming it would make one
# checkout answer to different names. Unset, it defaults to the
# checkout directory's name. Validated for the same reason: it lands
# inside eval'd shell output.
if [ "$COMPOSE_CONTEXT_BASE" = "" ] && [ -f "$project_dir/context.env" ]; then
  COMPOSE_CONTEXT_BASE="$(sed -n 's/^[[:space:]]*COMPOSE_CONTEXT_BASE=//p' "$project_dir/context.env" \
                          | head -n1 | tr -d "[:space:]\"'")"
fi
if [ "$COMPOSE_CONTEXT_BASE" != "" ] &&
  ! echo "$COMPOSE_CONTEXT_BASE" | grep -Eq "$context_name_re"; then
  echo "COMPOSE_CONTEXT_BASE ignored: '$COMPOSE_CONTEXT_BASE' is not a project name" >&2
  COMPOSE_CONTEXT_BASE=""
fi
name_base="${COMPOSE_CONTEXT_BASE:-$project_dir_name}"

# The COMPOSE_CTX_* knobs (see header): `context.<ctx>.env` overrides
# `context.env`, and the environment overrides both — per variable,
# with set-but-empty counting as set (an explicit "none"; that is how
# the wrapper's --no-override clears COMPOSE_CTX_OVERRIDES). Values
# are taken literally, never evaluated.
context_env_files="context.env"
if [ "$COMPOSE_CONTEXT" != "" ]; then
  context_env_files="context.${COMPOSE_CONTEXT}.env $context_env_files"
fi
for context_env_file in $context_env_files; do
  [ -f "$project_dir/$context_env_file" ] || continue
  # `|| [ -n "$line" ]`: a final line with no trailing newline still fills
  # `line` while read reports EOF — without this it would be dropped.
  while IFS= read -r line || [ -n "$line" ]; do
    # Tolerate indentation: strip leading whitespace before matching.
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
    COMPOSE_CTX_*=*) ;;
    *) continue ;;
    esac
    key="${line%%=*}"
    case "$key" in
    *[!A-Z0-9_]*) continue ;;
    esac
    if [ -z "${!key+set}" ]; then
      value="${line#*=}"
      # Trailing whitespace off first, so `KEY=value ` and `KEY="value" `
      # both come out as `value`; quotes are stripped after.
      value="${value%"${value##*[![:space:]]}"}"
      case "$value" in
      \"*\") value="${value%\"}"; value="${value#\"}" ;;
      \'*\') value="${value%\'}"; value="${value#\'}" ;;
      esac
      printf -v "$key" '%s' "$value"
    fi
  done <"$project_dir/$context_env_file"
done

# The fallback (see header): a context with no compose file of its own
# is just another name for the default stack, so drop it here and let
# everything below take the default path. Without this it would resolve
# to a project of its own — same compose file, different name, none of
# the containers: two stacks where the operator meant one.
if [ "$COMPOSE_CONTEXT" != "" ] && [ "$COMPOSE_CTX_FORCE_FILES" = "" ] &&
  [ "$(find_yml "docker-compose.${COMPOSE_CONTEXT}")" = "" ] &&
  [ "$(find_yml "compose.${COMPOSE_CONTEXT}")" = "" ]; then
  # Calling the default stack by its own name (`name:` in the base
  # file — a literal or a `${VAR:-...}` fallback, quotes stripped) is
  # expected
  # and stays silent; any other unknown context is a typo landing on
  # the default stack, and `down -v` on the wrong stack is not
  # something to discover afterwards — so say it on stderr, stdout
  # being eval'd.
  base_compose="$(find_yml docker-compose)"
  [ "$base_compose" != "" ] || base_compose="$(find_yml compose)"
  default_stack_name=$(tr -d "\"'" 2>/dev/null <"$project_dir/$base_compose" | sed -n \
    -e 's/^name: *[^ ]*:-\([A-Za-z0-9_-]*\)}.*/\1/p' \
    -e 's/^name: *\([A-Za-z0-9_-]*\) *$/\1/p' \
    | head -1)
  if [ "$COMPOSE_CONTEXT" != "$default_stack_name" ]; then
    echo "context '${COMPOSE_CONTEXT}' has no compose file of its own — using the default stack${default_stack_name:+ '$default_stack_name'}" >&2
  fi
  COMPOSE_CONTEXT=""
fi

if [ "$COMPOSE_CONTEXT" != "" ] && echo "$COMPOSE_CONTEXT" | grep -Eq "$context_name_re"; then
  # Re-eval safety (see header) for the project name, arm by arm:
  # anything this script could have produced (empty, the dir name,
  # <base>, or either with a previous context's suffix) rebuilds to
  # `<base>-<ctx>`; a name already ending in `-<ctx>` stays; a foreign,
  # hand-set name is kept as the base and suffixed once.
  case "$COMPOSE_PROJECT_NAME" in
  "" | "$project_dir_name" | "$project_dir_name"-* | "$name_base" | "$name_base"-*)
    COMPOSE_PROJECT_NAME="${name_base}-${COMPOSE_CONTEXT}"
    ;;
  *"-${COMPOSE_CONTEXT}") ;;
  *) COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}-${COMPOSE_CONTEXT}" ;;
  esac
  compose_stem="compose"
  context_compose_file="$(find_yml "docker-compose.${COMPOSE_CONTEXT}")"
  if [ "$context_compose_file" != "" ]; then
    compose_stem="docker-compose"
  else
    context_compose_file="$(find_yml "compose.${COMPOSE_CONTEXT}")"
  fi
  if [ "$context_compose_file" != "" ]; then
    COMPOSE_FILE="$context_compose_file"
  elif [ "$COMPOSE_CTX_FORCE_FILES" != "" ]; then
    COMPOSE_FILE="compose.${COMPOSE_CONTEXT}.yaml"
  fi
  #echo "echo \"COMPOSE_FILE=$COMPOSE_FILE\""
  if [ "$COMPOSE_CTX_FORCE_FILES" != "" ] || [ -f "$project_dir/${compose_stem}.${COMPOSE_CONTEXT}.env" ]; then
    COMPOSE_ENV_FILES="${compose_stem}.${COMPOSE_CONTEXT}.env"
  fi
  if [ "$COMPOSE_CTX_PROFILES" = "" ]; then
    COMPOSE_PROFILES="${COMPOSE_CONTEXT}"
  else
    # add context name to profiles if not already present
    if echo "$COMPOSE_CTX_PROFILES" | grep -Eq "(^|,)${COMPOSE_CONTEXT}(,|$)"; then
      COMPOSE_PROFILES="${COMPOSE_CTX_PROFILES}"
    else
      COMPOSE_PROFILES="${COMPOSE_CONTEXT},${COMPOSE_CTX_PROFILES}"
    fi
  fi
else
  # Named explicitly rather than left to compose's own upward search, so the
  # tiering below is the only thing that adds files.
  compose_stem="compose"
  base_compose_file="$(find_yml docker-compose)"
  if [ "$base_compose_file" != "" ]; then
    compose_stem="docker-compose"
  else
    base_compose_file="$(find_yml compose)"
  fi
  if [ "$base_compose_file" != "" ]; then
    COMPOSE_FILE="$base_compose_file"
  fi
  if [ "$COMPOSE_CTX_FORCE_FILES" != "" ] || [ -f "$project_dir/${compose_stem}.env" ]; then
    COMPOSE_ENV_FILES="${compose_stem}.env"
  fi
  # Re-eval safety here too: the same script-produced spellings reset.
  # A set COMPOSE_CONTEXT_BASE then names the default stack outright;
  # unset leaves compose's directory-derived default in force.
  case "$COMPOSE_PROJECT_NAME" in
  "" | "$project_dir_name" | "$project_dir_name"-* | "$name_base" | "$name_base"-*)
    COMPOSE_PROJECT_NAME="$COMPOSE_CONTEXT_BASE"
    ;;
  esac
  if [ "$COMPOSE_CTX_PROFILES" != "" ]; then
    COMPOSE_PROFILES="${COMPOSE_CTX_PROFILES}"
  fi
fi

# The override tiers (see header), appended to COMPOSE_FILE
# (colon-separated; compose merges left to right, appending list values
# and overriding scalars). Declared, never discovered:
# COMPOSE_CTX_OVERRIDES names every extra file, typically from
# `context[.<ctx>].env`, and --no-override clears it — how a second
# instance of a stack runs beside the first, these files being where
# daemon-global things (container names, subnets, a DNS address) are
# pinned.
#
# Placeholders keep one declaration portable: `%compose` is the base
# file's stem, `%context` the context name. `.%context` is the
# structural infix — for the default (empty) context the dot goes with
# it, so `%compose.%context.local` names `compose.local` there.
# examples/context.example.env shows the declaration in place.
overrides="$COMPOSE_CTX_OVERRIDES"
overrides="${overrides//%compose/$compose_stem}"
overrides="${overrides//.%context/${COMPOSE_CONTEXT:+.$COMPOSE_CONTEXT}}"
overrides="${overrides//%context/$COMPOSE_CONTEXT}"

# Each entry is an extensionless tier STEM: `<stem>.ya?ml` joins
# COMPOSE_FILE and `<stem>.env` joins COMPOSE_ENV_FILES, so one tier
# can carry compose config, redeclared variables (APP_VERSION=…), or
# both. An entry spelling a known extension names that one file
# literally. A tier matching nothing on disk is skipped with a stderr
# note: normal for a generic `%context` declaration, and a typo still
# shows itself instead of failing compose.
present=""
tier_envs=""
old_ifs="$IFS"
IFS=':'
for entry in $overrides; do
  [ "$entry" = "" ] && continue
  case "$entry" in
  *.yml | *.yaml)
    if [ -f "$project_dir/$entry" ]; then
      if [ "$present" = "" ]; then present="$entry"; else present="$present:$entry"; fi
    else
      echo "override tier $entry not found — skipped" >&2
    fi
    ;;
  *.env)
    if [ -f "$project_dir/$entry" ]; then
      if [ "$tier_envs" = "" ]; then tier_envs="$entry"; else tier_envs="$tier_envs,$entry"; fi
    else
      echo "override tier $entry not found — skipped" >&2
    fi
    ;;
  *)
    matched=""
    tier_yml="$(find_yml "$entry")"
    if [ "$tier_yml" != "" ]; then
      if [ "$present" = "" ]; then present="$tier_yml"; else present="$present:$tier_yml"; fi
      matched=1
    fi
    if [ -f "$project_dir/$entry.env" ]; then
      if [ "$tier_envs" = "" ]; then tier_envs="$entry.env"; else tier_envs="$tier_envs,$entry.env"; fi
      matched=1
    fi
    if [ "$matched" = "" ]; then
      echo "override tier $entry matched nothing — skipped" >&2
    fi
    ;;
  esac
done
IFS="$old_ifs"
overrides="$present"
if [ "$tier_envs" != "" ]; then
  if [ "$COMPOSE_ENV_FILES" = "" ]; then
    COMPOSE_ENV_FILES="$tier_envs"
  else
    COMPOSE_ENV_FILES="${COMPOSE_ENV_FILES},${tier_envs}"
  fi
fi

# The explicit escape hatch stays the strongest env layer: compose lets a
# later file override an earlier one.
if [ "$COMPOSE_CTX_ENV_FILES" != "" ]; then
  if [ "$COMPOSE_ENV_FILES" = "" ]; then
    COMPOSE_ENV_FILES=".env"
  fi
  COMPOSE_ENV_FILES="${COMPOSE_ENV_FILES},${COMPOSE_CTX_ENV_FILES}"
fi

if [ "$overrides" != "" ]; then
  if [ "$COMPOSE_FILE" = "" ]; then
    # Reachable only when no base file exists at all (the stem is then
    # "compose"), so the invented name is the canonical spelling.
    COMPOSE_FILE="compose.yaml"
  fi
  COMPOSE_FILE="${COMPOSE_FILE}:${overrides}"
fi

### PRINT ENVIRONMENT VARIABLES ###

if [ "$COMPOSE_CONTEXT" != "" ]; then
  echo "export COMPOSE_CONTEXT='$COMPOSE_CONTEXT'"
fi

if [ "$COMPOSE_PROJECT_PATH" != "" ] && [ "$COMPOSE_PROJECT_PATH" != "$project_dir" ]; then
  echo "export COMPOSE_PROJECT_PATH='$project_dir'"
fi

if [ "$COMPOSE_PROJECT_NAME" != "" ]; then
  echo "export COMPOSE_PROJECT_NAME='$COMPOSE_PROJECT_NAME'"
else
  echo "unset COMPOSE_PROJECT_NAME"
fi

if [ "$COMPOSE_FILE" != "" ]; then
  echo "export COMPOSE_FILE='$(anchor "$COMPOSE_FILE" ':')'"
else
  echo "unset COMPOSE_FILE"
fi

if [ "$COMPOSE_PROFILES" != "" ]; then
  echo "export COMPOSE_PROFILES='${COMPOSE_PROFILES}'"
else
  echo "unset COMPOSE_PROFILES"
fi

if [ "$COMPOSE_ENV_FILES" != "" ]; then
  echo "export COMPOSE_ENV_FILES='$(anchor "$COMPOSE_ENV_FILES" ',')'"
else
  echo "unset COMPOSE_ENV_FILES"
fi
