#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only|project-branch> <task-id>
# [<batch-branch>] prints the block on stdout with no trailing blank line. The
# caller validates the mode; an unknown mode is refused rather than silently
# rendered as the pipeline contract. project-branch REQUIRES the batch branch as
# the third argument and refuses without it, because that mode's whole contract is
# a branch the captain already owns rather than one derived from the task id.
# project-branch's contract ends at "ready for a pull request", not at an open PR:
# the worker announces the branch before it starts, runs the review pipeline with
# the push, pr, and ci steps skipped, and stops when it passes. Only a relayed
# captain instruction releases a later run that opens the PR.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against; the project-branch form
# extends that same line with " branch=<batch-branch>", which the spawn checks
# too so the brief's branch and the dispatched branch can never drift apart.
# This file is the one owner of the no-mistakes `--intent` contract: only the
# brief's `## Captain's intent` subsection plus later captain words, never
# `## Firstmate spec` and never the worker's own tradeoffs. bin/fm-brief.sh
# scaffolds those two `# Task` subsections; bin/fm-spawn.sh and bin/fm-promote.sh
# refuse leftover `{TASK}` / `{FIRSTMATE_SPEC}` placeholders through the helpers
# below. Other mentions of `--intent` point here rather than restating the rule.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

# Return 0 when a Task subsection still consists only of its scaffold
# placeholder. A missing file and legacy briefs carry no such placeholders.
fm_brief_task_placeholders_present() {  # <file>
  local file=$1 intent spec
  [ -f "$file" ] || return 1
  intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
  spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
  [ "$(printf '%s' "$intent" | tr -d '[:space:]')" = '{TASK}' ] && return 0
  [ "$(printf '%s' "$spec" | tr -d '[:space:]')" = '{FIRSTMATE_SPEC}' ] && return 0
  return 1
}

# Parse an exact ATX heading outside fenced blocks. Body mode prints through
# the next unfenced heading at the same or a higher level; present mode reports
# whether the heading exists.
fm_brief_heading_parse() {  # <file|-> <heading> <body|present>
  local file=$1 heading=$2 mode=$3 input=$1
  if [ "$file" = - ]; then
    input=/dev/stdin
  else
    [ -f "$file" ] || { [ "$mode" = body ]; return; }
  fi
  awk -v heading="$heading" -v mode="$mode" '
    BEGIN {
      target_level = 0
      while (substr(heading, target_level + 1, 1) == "#") target_level++
    }
    {
      line = $0
      scan = line
      spaces = 0
      while (spaces < 3 && substr(scan, 1, 1) == " ") {
        scan = substr(scan, 2)
        spaces++
      }
      marker = substr(scan, 1, 1)
      marker_len = 0
      if (marker == "`" || marker == "~") {
        while (substr(scan, marker_len + 1, 1) == marker) marker_len++
      }
      is_fence = marker_len >= 3
      was_fenced = fenced

      if (is_fence) {
        rest = substr(scan, marker_len + 1)
        if (!fenced) {
          fenced = 1
          fence_marker = marker
          fence_len = marker_len
        } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
          fenced = 0
        }
      }

      if (!found && !was_fenced && line == heading) {
        found = 1
        if (mode == "present") next
        grab = 1
        next
      }
      if (mode == "present" || !grab) next
      if (is_fence || was_fenced) {
        print line
        next
      }

      level = 0
      while (substr(scan, level + 1, 1) == "#") level++
      if (level > 0 && level <= target_level && substr(scan, level + 1, 1) ~ /^[[:space:]]?$/) exit
      print line
    }
    END {
      if (mode == "present" && !found) exit 1
    }
  ' "$input"
}

fm_brief_heading_body() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" body
}

fm_brief_heading_present() {  # <file> <heading>
  fm_brief_heading_parse "$1" "$2" present >/dev/null
}

fm_brief_task_heading_body() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" body
}

fm_brief_task_heading_present() {  # <file> <heading>
  local task
  task=$(fm_brief_heading_body "$1" "# Task")
  printf '%s\n' "$task" | fm_brief_heading_parse - "$2" present >/dev/null
}

fm_brief_marked_captain_words() {  # <task-body>
  printf '%s\n' "$1" | awk '
    match($0, /^[[:space:]]*Captain('\''s (words|ask|intent))?:[[:space:]]*/) {
      words = substr($0, RLENGTH + 1)
      if (words ~ /[^[:space:]]/) print words
    }
  '
}

fm_brief_intent_overlay() {  # <captain-intent>
  cat <<'EOF'

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use the serialized captain intent below plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.

## Captain intent authorized for --intent
EOF
  printf '%s\n' "$1"
  cat <<'EOF'

Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
EOF
}

# Accept the current two-subsection contract only when both bodies have content;
# briefs predating that contract remain valid when their # Task body has content.
fm_brief_task_content_valid() {  # <file>
  local file=$1 intent spec task has_intent=0 has_spec=0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  fm_brief_task_heading_present "$file" "## Captain's intent" && has_intent=1
  fm_brief_task_heading_present "$file" "## Firstmate spec" && has_spec=1
  if [ "$has_intent" -eq 1 ] || [ "$has_spec" -eq 1 ]; then
    [ "$has_intent" -eq 1 ] && [ "$has_spec" -eq 1 ] || return 1
    intent=$(fm_brief_task_heading_body "$file" "## Captain's intent")
    spec=$(fm_brief_task_heading_body "$file" "## Firstmate spec")
    [ -n "$(printf '%s' "$intent" | tr -d '[:space:]')" ] || return 1
    [ -n "$(printf '%s' "$spec" | tr -d '[:space:]')" ] || return 1
    return 0
  fi
  task=$(fm_brief_heading_body "$file" "# Task")
  [ -n "$(printf '%s' "$task" | tr -d '[:space:]')" ]
}

# The no-mistakes pipeline guidance, shared verbatim by every mode that runs the
# pipeline. Extracted so mode=no-mistakes and mode=project-branch cannot drift:
# two hand-maintained copies of the ask-user escalation rule and the `--yes` ban
# would be exactly the delivery hole this file exists to close.
fm_dod_no_mistakes_pipeline_guidance() {
  cat <<'EOF'
You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection plus any later words the captain actually said.
For a legacy brief with no such subsection, include only words explicitly labeled `Captain:`, `Captain's words:`, `Captain's ask:`, or `Captain's intent:`; never copy its mixed `# Task` wholesale. If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.
EOF
}

fm_dod_block() {  # <mode> <task-id> [<batch-branch>]
  local mode=$1 id=$2 branch=${3-}
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file and stop.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

EOF
      fm_dod_no_mistakes_pipeline_guidance
      cat <<EOF

After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop. You are finished.
EOF
      ;;
    project-branch)
      if [ -z "$branch" ]; then
        echo "error: fm_dod_block: mode=project-branch requires the batch branch as its third argument; a project-branch task never derives its branch from the task id" >&2
        return 1
      fi
      cat <<EOF
# Definition of done
Delivery contract: mode=project-branch branch=$branch
This task ships **project-branch**: you work in the captain's own project directory, on the batch branch \`$branch\`, and you stop before the pull request.
Several tasks may land on \`$branch\` over time, so it is a batch branch, not this task's branch - never rename it, never derive a branch name from this task's id, and never open a second branch for your own work.

## Stage 1 - announce the branch, before anything else
The captain needs to know his project is occupied and by what.
Append \`working: branched $branch\` to the status file as your FIRST status line, before you change any code.
Do not skip this: it is how he learns which branch holds his project.

## Stage 2 - build it, bump the version, run the pipeline, then STOP
Iterate as long as you need: build, run, test, fix, repeat, committing to \`$branch\` as you go.

1. Bump the project's version on \`$branch\`, so the branch the captain reviews already contains it.
   Detect this project's own versioning mechanism from the project itself - the file, tag, or script it actually uses - rather than assuming a scheme.
   If you cannot determine it with confidence, append \`needs-decision: version bump mechanism unclear - {what you found}\` and stop. Never guess and never invent a versioning scheme.
2. Run \`no-mistakes doctor\`; if it reports the repo is not initialized here, run \`no-mistakes init\`.
   This is deliberately here and not at setup: nothing touches the captain's directory until the work is actually going out.
3. Run the review pipeline on \`$branch\` and let it fix what it finds, with the push, PR, and CI steps skipped:

   \`no-mistakes axi run --intent "<this brief's Captain's intent>" --skip push,pr,ci\`

   The \`--skip push,pr,ci\` is REQUIRED and is not yours to drop: it is what keeps a green pipeline from pushing or opening a PR on its own.
   Everything else about driving the pipeline is unchanged, including the gate rules below.
4. When the pipeline passes, append \`done: ready for a pull request on branch $branch - {summary}\` to the status file and stop. You are finished.

**Never open the pull request yourself, and never push, even when the pipeline is green.**
A passing pipeline is not authority to create a PR here.
The captain wants the reminder that the work is ready, and he decides when the PR happens; firstmate relays that word if it comes.
Your \`done:\` line must name the branch, because that reminder is the whole point of this stage.
You also never merge and never touch the default branch.

## Stage 3 - only if firstmate relays the captain's word to open the PR
Do nothing in this stage unless that instruction actually arrives.
Run the same pipeline again on \`$branch\` WITHOUT \`--skip\`, so its own push and PR steps run:

\`no-mistakes axi run --intent "<this brief's Captain's intent>"\`

After it reports CI green (the CI-ready return point - do not keep monitoring in the background until merge), append \`done: PR {url} checks green\` and stop.
The captain merges that PR himself and runs the deploy.

EOF
      fm_dod_no_mistakes_pipeline_guidance
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
