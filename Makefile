.PHONY: run test build app release clean

run:
	swift run NKJBlogPoster

test:
	swift test

build: app

app:
	./scripts/build-app.sh

# Requires Developer ID, Apple notarization credentials, and the Sparkle signing seed.
# Example: make release VERSION=0.1.0
release:
	@test -n "$(VERSION)" || (echo "VERSION is required (for example: make release VERSION=0.1.0)" >&2; exit 2)
	./scripts/release-macos.sh "$(VERSION)"

clean:
	swift package clean
