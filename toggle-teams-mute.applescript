on run {input, parameters}
	tell application "System Events"
		set previousPID to unix id of first application process whose frontmost is true
	end tell

	tell application id "com.microsoft.teams2" to activate
	delay 0.25

	tell application "System Events"
		keystroke "m" using {command down, shift down}
	end tell

	delay 0.1
	tell application "System Events"
		try
			set frontmost of first application process whose unix id is previousPID to true
		end try
	end tell

	return input
end run
