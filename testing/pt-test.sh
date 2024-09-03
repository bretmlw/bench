# launch_performance_test
# Purpose: This method downloads and runs the PassMark PerformanceTest benchmark
# Parameters:
#          1. TEST_URL - URL to download the PerformanceTest zip file
function launch_performancetest {
    TEST_URL="https://www.passmark.com/downloads/pt_linux_arm64.zip"
    TEST_NAME="PerformanceTest"
#    TEST_PATH=$YABS_PATH/${TEST_NAME,,}
    TEST_PATH="/home/bret/bench/pt-test-folder"
    ZIP_FILE="$TEST_PATH/pt_linux_arm64.zip"    
    mkdir -p "$TEST_PATH"

   # check for curl vs wget
    [[ ! -z $LOCAL_CURL ]] && DL_CMD="curl -sL -o" || DL_CMD="wget -q -O"
    echo -en "\nDownloading PassMark $TEST_NAME benchmark..."

    # download the zip file
    $DL_CMD "$ZIP_FILE" "$TEST_URL"

    echo -en "\nExtracting PassMark $TEST_NAME benchmark..."

    # extract the zip file
    unzip -q -o "$ZIP_FILE" -d "$TEST_PATH"

    echo -en "\nRunning PassMark $TEST_NAME benchmark..."

    # run the test and capture the output
    chmod +x "$TEST_PATH/PerformanceTest/pt_linux_arm64"
    TEST_RESULT=$("$TEST_PATH/PerformanceTest/pt_linux_arm64" -r 3 -d 2 2>&1)

    # process and display the results
    echo -en "\r\033[0K"
    echo -e "PassMark $TEST_NAME Benchmark Results:"
    echo -e "---------------------------------"
    # Parse and display the results
    CPU_MARK=$(echo "$TEST_RESULT" | grep "CPU Mark" | awk '{print $NF}')
    MEMORY_MARK=$(echo "$TEST_RESULT" | grep "Memory Mark" | awk '{print $NF}')

    echo "CPU Mark: $CPU_MARK"
    echo "Memory Mark: $MEMORY_MARK"

    # Add JSON output if needed
    if [ ! -z $JSON ]; then
        JSON_RESULT+='{"test":"PassMark_'$TEST_NAME'",'
        JSON_RESULT+='"cpu_mark":'$CPU_MARK','
        JSON_RESULT+='"memory_mark":'$MEMORY_MARK'}'
    fi
}

launch_performancetest
