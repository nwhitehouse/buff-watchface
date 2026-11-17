# Buff watch face: build helpers (macOS / Linux). Needs the Garmin Connect IQ SDK (install it with Garmin's SDK
# Manager) and a developer key (`make key` makes one). On Windows, use VS Code's Monkey C extension instead (README).
#
#   make build                 build bin/Buff.prg for DEVICE (default fenix847mm: the fēnix 8 47/51 mm)
#   make sim / run             start the simulator / build and load the face into it
#   make mockup                the face with fixed design-check values (Mock in source/BuffData.mc)
#   make test                  unit tests, in the simulator
#   make sideload              build and copy to a watch on USB (macOS; needs `brew install libmtp`)
#   make assets                rebuild images, fonts and layout from design/ (Python; see tools/build_assets.py)
#   make release               bin/release/Buff-<device>.prg for every watch in manifest.xml

DEVICE ?= fenix847mm
KEY    ?= $(HOME)/.garmin/developer_key.der
ifeq ($(shell uname),Darwin)
CIQ_DIR := $(HOME)/Library/Application Support/Garmin/ConnectIQ
else
CIQ_DIR := $(HOME)/.Garmin/ConnectIQ
endif
SDK    ?= $(shell cat "$(CIQ_DIR)/current-sdk.cfg" 2>/dev/null)
BIN    := bin
PRG    := $(BIN)/Buff.prg
DEVICES := $(shell sed -n 's/.*<iq:product id="\([^"]*\)".*/\1/p' manifest.xml)

.PHONY: check key build sim run mockup test sideload assets release clean

check:
	@test -n "$(SDK)" || (echo "No Connect IQ SDK found: install one with Garmin's SDK Manager (or pass SDK=/path)" && exit 1)
	@test -x "$(SDK)/bin/monkeyc" || (echo "monkeyc not found in $(SDK)" && exit 1)
	@test -f "$(KEY)" || (echo "No developer key at $(KEY): run 'make key' (or pass KEY=/path/to/key.der)" && exit 1)

## A developer key to sign your builds (keep it private; any key works for installing on your own watch)
key:
	@test ! -f "$(KEY)" || (echo "$(KEY) already exists" && exit 1)
	@mkdir -p "$(dir $(KEY))"
	openssl genrsa -out "$(KEY:.der=.pem)" 4096
	openssl pkcs8 -topk8 -inform PEM -outform DER -in "$(KEY:.der=.pem)" -out "$(KEY)" -nocrypt
	@echo "Developer key: $(KEY)"

## Build for the watch (release: optimised, no debug info)
build: check
	@mkdir -p $(BIN)
	"$(SDK)/bin/monkeyc" -d $(DEVICE) -f monkey.jungle -o $(PRG) -y "$(KEY)" -r -w

## Start the simulator (leave it running between runs)
sim: check
	"$(SDK)/bin/connectiq" &

## Build (debug) and load into the running simulator
run: check
	@mkdir -p $(BIN)
	"$(SDK)/bin/monkeyc" -d $(DEVICE) -f monkey.jungle -o $(BIN)/BuffDebug.prg -y "$(KEY)" -w
	"$(SDK)/bin/monkeydo" $(BIN)/BuffDebug.prg $(DEVICE)

## The face with fixed values (Mock in source/BuffData.mc), clock frozen at 14:32, in the running simulator
mockup: check
	@mkdir -p $(BIN)
	"$(SDK)/bin/monkeyc" -d $(DEVICE) -f mockup.jungle -o $(BIN)/BuffMockup.prg -y "$(KEY)" -w
	"$(SDK)/bin/monkeydo" $(BIN)/BuffMockup.prg $(DEVICE)

## Unit tests (source/test) in the running simulator
test: check
	@mkdir -p $(BIN)
	"$(SDK)/bin/monkeyc" -d $(DEVICE) -f monkey.jungle -o $(BIN)/BuffTest.prg -y "$(KEY)" --unit-test -w
	"$(SDK)/bin/monkeydo" $(BIN)/BuffTest.prg $(DEVICE) -t | tee $(BIN)/test.log; grep -q '^PASSED' $(BIN)/test.log

## Build and copy to the watch over USB (macOS). Start this BEFORE plugging the watch in. LOG=1 adds a timing log.
sideload: build
	tools/sideload.sh $(PRG)
	@echo "Unplug, then on the watch: hold MENU > Watch Face > Buff > Apply."

## Rebuild the face's images, fonts and layout from design/ (needs Python 3 with Pillow + numpy, and rsvg-convert)
assets:
	python3 tools/build_assets.py

## Release builds for every watch in manifest.xml
release: check
	@mkdir -p $(BIN)/release
	@for d in $(DEVICES); do \
		echo "== $$d"; \
		"$(SDK)/bin/monkeyc" -d $$d -f monkey.jungle -o $(BIN)/release/Buff-$$d.prg -y "$(KEY)" -r -w || exit 1; \
	done
	@rm -f $(BIN)/release/*.debug.xml

clean:
	rm -rf $(BIN)
