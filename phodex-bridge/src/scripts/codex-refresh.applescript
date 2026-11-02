-- FILE: codex-refresh.applescript
-- Purpose: Opens the target Codex deep link so the desktop window lands on the phone-driven thread.
-- Layer: UI automation helper
-- Args: bundle id, resolved app path, optional target deep link, optional launch-if-closed flag ("1" default)
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

  set hasAppPath to my isInstalledApp(appPath)
  if hasAppPath then
    set runningSelector to "bundlepath=" & quoted form of appPath
    set openSelector to "-a " & quoted form of appPath
  else
    set runningSelector to "bundleid=" & quoted form of bundleId
    set openSelector to "-b " & quoted form of bundleId
  end if

  -- Navigation is a courtesy for the selected app only when already open.
  if launchIfClosed is "0" and not my isCodexRunning(runningSelector) then
    return
  end if

  set commandText to "open " & openSelector
  if targetUrl is not "" then
    set commandText to commandText & " " & quoted form of targetUrl
  end if
  do shell script commandText

  if not hasAppPath then
    delay 0.18
    try
      tell application id bundleId to activate
    end try
  end if
end run

on isInstalledApp(appPath)
  if appPath is "" then return false
  try
    do shell script "/usr/bin/test -f " & quoted form of (appPath & "/Contents/Info.plist")
    return true
  on error
    return false
  end try
end isInstalledApp

on isCodexRunning(runningSelector)
  try
    -- Avoid System Events here: LaunchAgents may not have automation permission.
    set matches to do shell script "/usr/bin/lsappinfo find " & runningSelector
    return matches is not ""
  on error
    return false
  end try
end isCodexRunning
