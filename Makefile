APP = build/XDRLift.app
SWIFT_SRC = app/main.swift app/Booster.swift app/ClearView.swift
FRAMEWORKS = -framework AppKit -framework Metal -framework MetalKit -framework QuartzCore -framework Carbon -framework ServiceManagement

app: $(APP)

$(APP): $(SWIFT_SRC) app/Info.plist
	mkdir -p $(APP)/Contents/MacOS
	swiftc -O -swift-version 5 $(SWIFT_SRC) $(FRAMEWORKS) -o $(APP)/Contents/MacOS/XDRLift
	cp app/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)
	touch $(APP)

# Boosts the XDR screen, pulses 1.0x <-> 1.4x every 2 s for 12 s, logs headroom / table, exits.
# Quits the menu bar instance for the run (two would fight over the gamma table) and reopens it.
selftest: $(APP)
	@was=$$(pgrep -x XDRLift); pkill -x XDRLift; \
	 for i in $$(seq 50); do pgrep -x XDRLift >/dev/null || break; sleep 0.1; done; \
	 perl -e 'alarm shift; exec @ARGV' 20 $(APP)/Contents/MacOS/XDRLift --selftest 12; \
	 if [ -n "$$was" ]; then open /Applications/XDRLift.app; fi

install: $(APP)
	-pkill -x XDRLift
	@# Wait (up to 5 s, then SIGKILL) so `open` can't just re-activate the dying instance. Killing is
	@# safe for the screen: the overlay windows die with the process.
	@for i in $$(seq 50); do pgrep -x XDRLift >/dev/null || break; sleep 0.1; done; \
	 if pgrep -x XDRLift >/dev/null; then pkill -9 -x XDRLift; sleep 0.5; fi
	rm -rf /Applications/XDRLift.app
	cp -R $(APP) /Applications/XDRLift.app
	open /Applications/XDRLift.app

clean:
	rm -rf build

.PHONY: app selftest install clean
