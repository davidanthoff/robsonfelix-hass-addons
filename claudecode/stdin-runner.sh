#!/bin/bash
# Headless Claude Code runs triggered from Home Assistant automations.
#
# An automation calls the built-in hassio.addon_stdin service with a JSON
# payload; the Supervisor delivers it here on stdin, one JSON object per
# line:
#
#   {"prompt": "...", "model": "sonnet", "run_id": "my-task"}
#   {"prompt_file": "/share/task.md", "allowed_tools": ["mcp__homeassistant__*"]}
#
# Fields (all optional except one of prompt/prompt_file):
#   prompt          inline prompt text
#   prompt_file     path to a prompt file visible inside the add-on
#   model           model override (else default_task_model option)
#   allowed_tools   list of tool permissions (else default_task_allowed_tools)
#   run_id          label used in events and the log file name
#
# Each run executes `claude -p` as the same authenticated user as the web
# terminal. Runs are serialized. Outcomes are reported as Home Assistant
# events `claudecode_run_started` / `claudecode_run_finished` so automations
# can react (announce, notify, retry).

OPTS=/data/options.json
DEFAULT_MODEL=$(jq -r '.default_task_model // ""' "$OPTS")
DEFAULT_TOOLS=$(jq -c '.default_task_allowed_tools // []' "$OPTS")
MAX_MINUTES=$(jq -r '.task_max_runtime_minutes // 30' "$OPTS")

LOG_DIR=/config/task-logs
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR=/homeassistant/.claudecode/task-logs
mkdir -p "$LOG_DIR"

fire_event() {
    local event="$1" payload="$2"
    curl -s -m 10 -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://supervisor/core/api/events/${event}" > /dev/null
}

echo "[INFO] stdin task runner ready (default model: ${DEFAULT_MODEL:-claude default}, max ${MAX_MINUTES} min)"

while IFS= read -r line; do
    [ -z "$line" ] && continue
    if ! jq -e . > /dev/null 2>&1 <<< "$line"; then
        echo "[WARN] task runner: ignoring non-JSON stdin line"
        continue
    fi
    RUN_ID=$(jq -r '.run_id // "task"' <<< "$line")
    MODEL=$(jq -r '.model // empty' <<< "$line")
    [ -z "$MODEL" ] && MODEL="$DEFAULT_MODEL"
    TOOLS=$(jq -c 'if (.allowed_tools // []) | length > 0 then .allowed_tools else empty end' <<< "$line")
    [ -z "$TOOLS" ] && TOOLS="$DEFAULT_TOOLS"
    PROMPT=$(jq -r '.prompt // empty' <<< "$line")
    PROMPT_FILE=$(jq -r '.prompt_file // empty' <<< "$line")
    if [ -z "$PROMPT" ] && [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ]; then
        PROMPT=$(cat "$PROMPT_FILE")
    fi
    if [ -z "$PROMPT" ]; then
        echo "[WARN] task runner: run '$RUN_ID' has no prompt/prompt_file - skipped"
        fire_event claudecode_run_finished \
            "$(jq -n --arg id "$RUN_ID" '{run_id: $id, success: false, error: "no prompt provided"}')"
        continue
    fi

    TS=$(date +%Y%m%d-%H%M%S)
    LOG_FILE="${LOG_DIR}/${RUN_ID}-${TS}.log"
    ARGS=(-p "$PROMPT")
    [ -n "$MODEL" ] && ARGS+=(--model "$MODEL")
    TOOL_COUNT=$(jq -r 'length' <<< "$TOOLS")
    if [ "$TOOL_COUNT" -gt 0 ]; then
        while IFS= read -r tool; do
            ARGS+=(--allowedTools "$tool")
        done < <(jq -r '.[]' <<< "$TOOLS")
    fi

    echo "[INFO] task runner: starting '$RUN_ID' (model: ${MODEL:-default}, ${TOOL_COUNT} allowed tools, log: $LOG_FILE)"
    fire_event claudecode_run_started \
        "$(jq -n --arg id "$RUN_ID" --arg log "$LOG_FILE" '{run_id: $id, log_path: $log}')"
    START=$(date +%s)
    timeout "$((MAX_MINUTES * 60))" claude "${ARGS[@]}" > "$LOG_FILE" 2>&1
    CODE=$?
    DURATION=$(( $(date +%s) - START ))
    SUCCESS=false
    [ "$CODE" -eq 0 ] && SUCCESS=true
    TAIL=$(tail -c 400 "$LOG_FILE")
    echo "[INFO] task runner: '$RUN_ID' finished (exit $CODE, ${DURATION}s)"
    fire_event claudecode_run_finished \
        "$(jq -n --arg id "$RUN_ID" --arg log "$LOG_FILE" \
              --argjson ok "$SUCCESS" --argjson code "$CODE" \
              --argjson dur "$DURATION" --arg tail "$TAIL" \
              '{run_id: $id, success: $ok, exit_code: $code, duration_seconds: $dur, log_path: $log, output_tail: $tail}')"
done
echo "[INFO] task runner: stdin closed, exiting"
