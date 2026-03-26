.PHONY: build clean run test

BINARY_NAME = diahistory
BUILD_DIR = .build/release
SIGNING_IDENTITY ?= -

build:
	swift build -c release
	codesign --force --sign "$(SIGNING_IDENTITY)" "$(BUILD_DIR)/$(BINARY_NAME)"

clean:
	swift package clean
	rm -rf .build

run:
	swift run $(BINARY_NAME)

test:
	swift test
