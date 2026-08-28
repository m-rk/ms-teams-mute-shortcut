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
		set frontmost of application process "MSTeams" to true
		set teamsProcesses to every application process whose name contains "Teams"
		set micControl to missing value

		repeat with teamsProcess in teamsProcesses
			tell teamsProcess
				repeat with teamsWindow in windows
					repeat with candidateElement in entire contents of teamsWindow
						set candidateName to ""
						set candidateDescription to ""
						try
							set candidateName to name of candidateElement
						end try
						try
							set candidateDescription to description of candidateElement
						end try
						if candidateName is "Mute mic" or candidateName is "Unmute mic" or candidateDescription is "Mute mic" or candidateDescription is "Unmute mic" then
							set micControl to candidateElement
							exit repeat
						end if
					end repeat
					if micControl is not missing value then exit repeat
				end repeat
			end tell
			if micControl is not missing value then exit repeat
		end repeat

		if micControl is missing value then
			error "Could not find the Teams microphone control."
		end if
		click micControl
	end tell

	delay 0.1
	tell application "System Events"
		try
			set frontmost of first application process whose unix id is previousPID to true
		end try
	end tell
end toggleTeamsMute
