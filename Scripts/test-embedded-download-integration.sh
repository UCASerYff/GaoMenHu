#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESUME_STAGE="${1:-all}"
[[ "$RESUME_STAGE" == all || "$RESUME_STAGE" == migration || "$RESUME_STAGE" == review || "$RESUME_STAGE" == ingress || "$RESUME_STAGE" == contracts ]] || { echo "Unknown focused resume stage" >&2; exit 1; }
TASK_ROOT=$(mktemp -d /private/tmp/portal-download-integration.XXXXXX)
mkdir -m 700 "$TASK_ROOT/Tests.noindex"
TEST_DIR="$TASK_ROOT/Tests.noindex"
trap 'rm -rf "$TASK_ROOT"' EXIT
# Caller holds the integration Master/build_lease.py; no GUI or real data access.
CORE=("$PROJECT_DIR/Sources/Downloads/DownloadModels.swift" "$PROJECT_DIR/Sources/Downloads/DownloadStore.swift" "$PROJECT_DIR/Sources/Downloads/HTTPTransfer.swift")
EXCHANGE=("$PROJECT_DIR/Sources/Downloads/DownloadActionPackage.swift" "$PROJECT_DIR/Sources/Downloads/DownloadExchangeJournal.swift" "$PROJECT_DIR/Sources/Downloads/DownloadExchange.swift")
MIGRATION=("$PROJECT_DIR/Sources/Downloads/DownloadMigration.swift" "$PROJECT_DIR/Sources/Downloads/DownloadHistoryIsolation.swift")
PORTAL=("$PROJECT_DIR/Sources/Models.swift" "$PROJECT_DIR/Sources/GaoActionPackage.swift" "$PROJECT_DIR/Sources/PortalActions.swift" "$PROJECT_DIR/Sources/PortalDownloadResults.swift")
FLAGS=(-swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$TEST_DIR/cache")
if [[ "$RESUME_STAGE" == all ]]; then
xcrun swiftc "${FLAGS[@]}" "${CORE[@]}" "${EXCHANGE[@]}" "${MIGRATION[@]}" "$PROJECT_DIR/Tests/EmbeddedDownloadExchangeTests.swift" -framework AppKit -framework CryptoKit -framework Security -o "$TEST_DIR/exchange"
"$TEST_DIR/exchange"
fi
if [[ "$RESUME_STAGE" == all || "$RESUME_STAGE" == migration ]]; then
xcrun swiftc "${FLAGS[@]}" "${CORE[@]}" "${EXCHANGE[@]}" "${MIGRATION[@]}" "$PROJECT_DIR/Tests/DownloadMigrationTests.swift" -framework AppKit -framework CryptoKit -framework Security -o "$TEST_DIR/migration"
"$TEST_DIR/migration"
fi
if [[ "$RESUME_STAGE" == all || "$RESUME_STAGE" == migration || "$RESUME_STAGE" == review ]]; then
xcrun swiftc "${FLAGS[@]}" "${PORTAL[@]}" "${CORE[@]}" "${EXCHANGE[@]}" "${MIGRATION[@]}" \
 "$PROJECT_DIR/Sources/Downloads/DownloadMountEpoch.swift" "$PROJECT_DIR/Sources/Downloads/DownloadManager.swift" "$PROJECT_DIR/Sources/Downloads/DownloadCoordinator.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadViews.swift" "$PROJECT_DIR/Sources/Downloads/DownloadComposerViews.swift" \
 "$PROJECT_DIR/Sources/Downloads/DownloadSettingsView.swift" "$PROJECT_DIR/Tests/EmbeddedDownloadReviewTests.swift" \
 -framework AppKit -framework SwiftUI -framework CryptoKit -framework Security -framework Network -o "$TEST_DIR/review"
"$TEST_DIR/review"
fi
if [[ "$RESUME_STAGE" != contracts ]]; then
xcrun swiftc "${FLAGS[@]}" "$PROJECT_DIR/Sources/PortalDownloadIngress.swift" "$PROJECT_DIR/Tests/PortalDownloadIngressTests.swift" -o "$TEST_DIR/ingress"
"$TEST_DIR/ingress"
fi
for fixture in PortalActionsTests PortalDownloadResultsTests PortalExchangeRoutingTests; do
 xcrun swiftc "${FLAGS[@]}" "${PORTAL[@]}" "$PROJECT_DIR/Tests/$fixture.swift" -framework Security -o "$TEST_DIR/$fixture"
 "$TEST_DIR/$fixture"
done
