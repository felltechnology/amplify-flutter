#!/bin/bash

set -euo pipefail

if [ ! -d ios ]; then
    echo "No iOS project to test" >&2
    exit
fi

DEFAULT_DEVICE_ID="iPhone"
DEFAULT_ENABLE_CLOUD_SYNC="true"

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--device-id)
            deviceId="$2"
            ;;
        -ec|--enable-cloud-sync)
            case "$2" in
                true|false)
                    enableCloudSync="$2"
                ;;
                *)
                    echo "Invalid value for $1"
                    exit 1
            esac
            ;;
        *)
            echo "Invalid arguments"
            exit 1
    esac
    shift
    shift
done

deviceId=${deviceId:-$DEFAULT_DEVICE_ID}
enableCloudSync=${enableCloudSync:-$DEFAULT_ENABLE_CLOUD_SYNC}

declare -a testsList
declare -a resultsList

TARGET=integration_test/main_test.dart
if [ ! -e $TARGET ]; then
    echo "$TARGET file not found" >&2
    exit
fi



# Use xcodebuild if 'RunnerTests' scheme exists, else `flutter test`
if xcodebuild -workspace ios/Runner.xcworkspace -list -json | jq -e '.workspace.schemes | index("RunnerTests")' >/dev/null; then
    # Build app for testing
    flutter build ios --no-pub --config-only --simulator --target=$TARGET

    xcodebuild \
        -workspace ios/Runner.xcworkspace \
        -scheme RunnerTests \
        -destination "platform=iOS Simulator,name=iPhone 12 Pro Max" \
        test
else
    testsList+=("$TARGET")
    if flutter test \
        --no-pub \
        -d $deviceId \
        $TARGET; then
        resultsList+=(0)
    else
        resultsList+=(1)
    fi
fi

TEST_ENTRIES="integration_test/separate_integration_tests/*.dart"
for ENTRY in $TEST_ENTRIES; do
    if [ ! -f "${ENTRY}" ]; then
        continue
    fi
    testsList+=("$ENTRY")
    if [ $enableCloudSync == "true" ]; then
        echo "Run $ENTRY WITH API Sync"
    else
        echo "Run $ENTRY WITHOUT API Sync"
    fi

    if flutter test \
        --no-pub \
        --dart-define ENABLE_CLOUD_SYNC=$enableCloudSync \
        -d $deviceId \
        $ENTRY; then
        resultsList+=(0)
    else
        resultsList+=(1)
    fi
done

testFailure=0
for i in "${!testsList[@]}"; do
    if [ "${resultsList[i]}" == 0 ]; then
        echo "✅ ${testsList[i]}"
    else
        testFailure=1
        echo "❌ ${testsList[i]}"
    fi
done

exit $testFailure
