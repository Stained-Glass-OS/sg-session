// sg-mklnk.js LINK TARGET [DESCRIPTION]
//
// Create a Windows shortcut (.lnk). Run with Wine's cscript by
// sg-install-apps: Wine has no command-line shortcut writer, but its
// WScript.Shell object implements CreateShortcut, which writes a real .lnk --
// the format sg-start and every Windows program reads.
var a = WScript.Arguments;
if (a.length < 2) {
    WScript.Echo("usage: sg-mklnk.js LINK TARGET [DESCRIPTION]");
    WScript.Quit(2);
}
var s = new ActiveXObject("WScript.Shell").CreateShortcut(a(0));
s.TargetPath = a(1);
if (a.length > 2) s.Description = a(2);
s.Save();
