-- FILE: codex-handoff.applescript
-- Purpose: Performs an explicit Codex.app relaunch before opening the requested thread.
-- Layer: UI automation helper
-- Args: bundle id, app path fallback, optional target deep link

on run argv
  set bundleId to item 1 of argv
  set appPath to item 2 of argv
  set targetUrl to ""
  set appName to my resolveAppName(bundleId, appPath)

  if (count of argv) is greater than or equal to 3 then
    set targetUrl to item 3 of argv
  end if

  try
    tell application id bundleId to activate
  end try

  delay 0.1

  try
    tell application id bundleId to quit
  end try

  my confirmQuitPrompt(appName)
  my waitForAppExit(appName, 40)
  my openCodex(bundleId, appPath, "")
  delay 1.2

  if targetUrl is not "" then
    my openCodex(bundleId, appPath, targetUrl)
  end if

  delay 0.2
  try
    tell application id bundleId to activate
  end try
end run

on resolveAppName(bundleId, appPath)
  try
    tell application id bundleId to return name
  on error
    return do shell script "basename " & quoted form of appPath & " .app"
  end try
end resolveAppName

on confirmQuitPrompt(appName)
  repeat 20 times
    try
      tell application "System Events"
        if exists process appName then
          tell process appName
            repeat with candidateWindow in windows
              if exists button "Quit" of candidateWindow then
                click button "Quit" of candidateWindow
                return
              end if
            end repeat
          end tell
        end if
      end tell
    end try

    delay 0.15
  end repeat
end confirmQuitPrompt

on waitForAppExit(appName, maxAttempts)
  repeat maxAttempts times
    try
      tell application "System Events"
        if not (exists process appName) then
          return
        end if
      end tell
    on error
      return
    end try

    delay 0.15
  end repeat
end waitForAppExit

on openCodex(bundleId, appPath, targetUrl)
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
end openCodex
