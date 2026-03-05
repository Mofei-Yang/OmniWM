.PHONY: format lint lint-fix check zig-build niri-phase0-perf-gate

format:
	swiftformat .

lint:
	swiftlint lint

lint-fix:
	swiftlint lint --fix

check: lint

# Build the Zig static library used by Swift.
# Default output is universal (arm64 + x86_64). Set ZIG_TARGET for single-arch.
zig-build:
	./build-zig.sh

niri-phase0-perf-gate:
	./Scripts/niri-phase0-perf-gate.sh
