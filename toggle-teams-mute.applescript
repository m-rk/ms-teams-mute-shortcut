use scripting additions

on run {input, parameters}
	set helperExecutable to (system attribute "HOME") & "/Applications/Teams Mute Helper.app/Contents/MacOS/TeamsMuteHelper"
	do shell script quoted form of helperExecutable
	return input
end run
