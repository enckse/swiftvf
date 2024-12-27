BIN     := build/
CLI     := $(BIN)main
BUNDLE  := $(BIN)Release/vfu.app
OBJECTS := $(CLI)
SOURCE  := $(shell find vfu/ -type f)
FLAGS   :=
VERS    := $(BUNDLE)/Contents/Resources/vers.txt

all: $(BUNDLE)

$(CLI): $(SOURCE)
	mkdir -p $(BIN)
	swiftc $(FLAGS) -O vfu/src/*.swift vfu/$(shell basename $@).swift -o $@
	codesign --entitlements vfu/vfu.entitlements --force -s - $@

clean:
	rm -rf $(BIN)

check: $(CLI)
	$(CLI) --help
	@touch $(BIN)apkovl.img $(BIN)alpine-aarch64.iso $(BIN)data.img
	@for file in examples/*; do \
		echo "testing: $$file"; \
		$(CLI) --config $$file --verify; \
		cat $$file | $(CLI) --config - --verify; \
	done

$(BUNDLE): $(CLI)
	xcodebuild archive -archivePath "$(BIN)vfu.app" -scheme "vfu" -sdk "macosx" -configuration Release CODE_SIGNING_ALLOWED=NO
	xcodebuild
	git describe --tags --abbrev=0 > $(VERS)
	git log $(git describe --tags --abbrev=0)..HEAD --oneline | wc -l >> $(VERS)
	cp $(CLI) $(BUNDLE)/Contents/MacOS/vfu-cli

install:
	cp -r $(BUNDLE) /Applications/
