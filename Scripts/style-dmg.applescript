on run arguments
    set mountPath to item 1 of arguments
    set mountedFolder to POSIX file mountPath as alias

    tell application "Finder"
        open mountedFolder
        delay 1
        set dmgWindow to front window
        set current view of dmgWindow to icon view
        set toolbar visible of dmgWindow to false
        set statusbar visible of dmgWindow to false
        set pathbar visible of dmgWindow to false
        set sidebar width of dmgWindow to 0
        set bounds of dmgWindow to {100, 100, 700, 500}

        set viewOptions to icon view options of dmgWindow
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 14
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to true

        set position of item "Say It.app" of mountedFolder to {160, 190}
        set position of item "Applications" of mountedFolder to {440, 190}

        update mountedFolder without registering applications
        delay 2
        close dmgWindow
    end tell
end run
