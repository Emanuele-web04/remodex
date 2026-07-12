// FILE: rollout-turn-semantics.js
// Purpose: Shared desktop rollout turn-lifecycle semantics for the live mirror
// and the JSONL history fallback, so both agree on what ends a run.

// Any of these event_msg types ends a desktop run; task_complete is not the only
// terminal outcome (Stop on desktop writes turn_aborted, fatal failures write error).
const TERMINAL_TASK_EVENT_TYPES = new Set(["task_complete", "turn_aborted", "error"]);

// Desktop interleaves parallel turns in one rollout file. A terminal event only
// closes the tracked turn when it targets that turn, carries no explicit id, or
// nothing is tracked; a sibling turn's terminal event must leave the tracked
// run open.
function terminalEventClosesTrackedTurn(eventTurnId, trackedTurnId) {
  return !eventTurnId || !trackedTurnId || eventTurnId === trackedTurnId;
}

module.exports = {
  TERMINAL_TASK_EVENT_TYPES,
  terminalEventClosesTrackedTurn,
};
