.PHONY: run test build app release clean

run:
	swift run NKJBlogPoster

test:
	swift test

build: app

app:
	./scripts/build-app.sh

# Requires a Developer ID signing identity and Apple notarization API credentials.
# Example: make release VERSION=0.1.0
release:
	@test -n "$(VERSION)" || (echo "VERSION is required (for example: make release VERSION=0.1.0)" >&2; exit 2)
	./scripts/release-macos.sh "$(VERSION)"

clean:
	swift package clean
