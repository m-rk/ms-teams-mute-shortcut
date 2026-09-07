use scripting additions

on run {input, parameters}
	set helperExecutable to (POSIX path of (path to home folder)) & "Applications/Teams Mute Helper.app/Contents/MacOS/TeamsMuteHelper"
	set helperCommand to quoted form of helperExecutable
	do shell script (helperCommand & " --toggle")
	return input
end run
