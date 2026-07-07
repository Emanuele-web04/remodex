-- FILE: codex-refresh.applescript
-- Purpose: Opens the target Codex deep link so the desktop window lands on the phone-driven thread.
-- Layer: UI automation helper
-- Args: bundle id, app path fallback, optional target deep link, optional launch-if-closed flag ("1" default)
-- Note: content updates stream over desktop IPC live sync, so no settings-route
-- bounce/remount is needed anymore; that bounce caused visible page flipping.

on run argv
  set bundleId to item 1 of argv
  set appPath to item 2 of argv
  set targetUrl to ""
  set launchIfClosed to "1"

  if (count of argv) is greater than or equal to 3 then
    set targetUrl to item 3 of argv
  end if

  if (count of argv) is greater than or equal to 4 then
    set launchIfClosed to item 4 of argv
  end if

  -- Navigation is a courtesy for an already-open Codex; cold-starting the app
  -- just to show the phone-driven thread is disruptive and never required for
  -- content sync (that streams over desktop IPC).
  if launchIfClosed is "0" and not my isCodexRunning(bundleId) then
    return
  end if

  my openCodexUrl(bundleId, appPath, targetUrl)

  delay 0.18
  try
    tell application id bundleId to activate
  end try
end run

on isCodexRunning(bundleId)
  try
    -- Avoid System Events here: LaunchAgents may not have automation permission.
    set matches to do shell script "/usr/bin/lsappinfo find bundleid=" & quoted form of bundleId
    return matches is not ""
  on error
    -- Unknown running state must fail closed for navigation-only callers.
    return false
  end try
end isCodexRunning

on openCodexUrl(bundleId, appPath, targetUrl)
  try
    if targetUrl is not "" then
      do shell script "open -b " & quoted form of bundleId & " " & quoted form of targetUrl
    else
      do shell script "open -b " & quoted form of bundleId
    end if
  on error
    if targetUrl is not "" then
      do shell script "open -a " & quoted form of appPath & " " & quoted form of targetUrl
    else
      do shell script "open -a " & quoted form of appPath
    end if
  end try
end openCodexUrl
