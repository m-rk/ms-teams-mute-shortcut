on run
	my runAndQuit()
end run

on reopen
	my runAndQuit()
end reopen

on runAndQuit()
	try
		my toggleTeamsMute()
	on error errorMessage number errorNumber
		tell current application to quit
		error errorMessage number errorNumber
	end try

	tell current application to quit
end runAndQuit

on toggleTeamsMute()
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
end toggleTeamsMute
