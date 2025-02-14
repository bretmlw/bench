#!/bin/bash

# Check if script is run as root or with sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root or with sudo."
    exit 1
fi

# User-definable variables
UNIXBENCH_NUMBER_OF_RUNS=1
PERFORMANCETEST_AUTORUN_VALUE=3
PERFORMANCETEST_DURATION=2
CPUMINER_TEST_DURATION=300 # Default duration in seconds

# Yet Another Bench Script by Mason Rowe
# Initial Oct 2019; Last update Jun 2024

# Disclaimer: This project is a work in progress. Any errors or suggestions should be
#             relayed to me via the GitHub project page linked below.
#
# Purpose:    The purpose of this script is to quickly gauge the performance of a Linux-
#             based server by benchmarking network performance via iperf3, CPU and
#             overall system performance via Geekbench 4/5, and random disk
#             performance via fio. The script is designed to not require any dependencies
#             - either compiled or installed - nor admin privileges to run.

YABS_VERSION="v2024-06-09"

echo -e '# ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## #'
echo -e '#                     BretBench                      #'
echo -e '#                  '$YABS_VERSION'                   #'
echo -e '#          https://github.com/bretmlw/bench          #'
echo -e '# ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## ## #'

echo -e
date
TIME_START=$(date '+%Y%m%d-%H%M%S')
YABS_START_TIME=$(date +%s)

# override locale to eliminate parsing errors (i.e. using commas as delimiters rather than periods)
if locale -a 2>/dev/null | grep ^C$ > /dev/null; then
	# locale "C" installed
	export LC_ALL=C
else
	# locale "C" not installed, display warning
	echo -e "\nWarning: locale 'C' not detected. Test outputs may not be parsed correctly."
fi

# Declare DISK_RESULTS as an associative array
declare -A DISK_RESULTS

# Function to check and install necessary apt packages
check_and_install_packages() {
    echo -e "\nChecking and Installing Necessary Packages:"
    echo -e "---------------------------------"
    
    PACKAGES=("fio" "bc" "iperf3" "unzip" "bmon" "git" "curl" "wget" "lscpu" "stress-ng" "jq" "libncurses5" "autoconf" "make" "automake" "autotools-dev" "libcurl4-openssl-dev" "libgmp-dev" "libgmpxx4ldbl" "libjansson-dev" "libssl-dev" "zlib*")
    PACKAGES_TO_INSTALL=()
    NOT_FOUND_PACKAGES=()

    for pkg in "${PACKAGES[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            PACKAGES_TO_INSTALL+=("$pkg")
        fi
    done

    if [ ${#PACKAGES_TO_INSTALL[@]} -eq 0 ]; then
        echo "All necessary apt packages found, continuing!"
    else
        echo "Installing missing packages..."
        for pkg in "${PACKAGES_TO_INSTALL[@]}"; do
            echo -n "Installing $pkg... "
            if sudo apt install -y "$pkg" >/dev/null 2>&1; then
                echo -e "\e[32m✓\e[0m"
            else
                echo -e "\e[31m✗\e[0m"
                NOT_FOUND_PACKAGES+=("$pkg")
            fi
        done
        
        if [ ${#NOT_FOUND_PACKAGES[@]} -gt 0 ]; then
            echo "The following packages were not found:"
            for pkg in "${NOT_FOUND_PACKAGES[@]}"; do
                echo -e "$pkg: \e[31mNot found ✗\e[0m"
            done
            
            read -p "Do you want to continue? (Y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]]; then
                echo "Aborting..."
                exit 1
            fi
        fi
    fi
}

# Call the function to check and install packages
check_and_install_packages

# Function to check load average and wait if necessary
check_load_average() {
    echo -e "Checking system load... "
    while true; do
        load=$(cat /proc/loadavg | awk '{print $1}')
        if (( $(echo "$load < 0.1" | bc -l) )); then
            echo -e "\nLoad average is below 0.1. Proceeding with benchmarking."
            break
        else
            echo -e "\nCurrent load: $load. Waiting for 5 seconds... "
            sleep 5
        fi
    done
}

# determine architecture of host
ARCH=$(uname -m)
if [[ $ARCH = *x86_64* ]]; then
	# host is running a 64-bit kernel
	ARCH="x64"
elif [[ $ARCH = *i?86* ]]; then
	# host is running a 32-bit kernel
	ARCH="x86"
elif [[ $ARCH = *aarch* || $ARCH = *arm* ]]; then
	KERNEL_BIT=$(getconf LONG_BIT)
	if [[ $KERNEL_BIT = *64* ]]; then
		# host is running an ARM 64-bit kernel
		ARCH="aarch64"
	else
		# host is running an ARM 32-bit kernel
		ARCH="arm"
	fi
else
	# host is running a non-supported kernel
	echo -e "Architecture not supported by YABS."
	exit 1
fi

# flags to skip certain performance tests
unset PREFER_BIN SKIP_FIO SKIP_IPERF SKIP_GEEKBENCH SKIP_NET PRINT_HELP GEEKBENCH_6 DD_FALLBACK IPERF_DL_FAIL JSON JSON_SEND JSON_RESULT JSON_FILE
GEEKBENCH_6="True" # gb6 test enabled by default

# get any arguments that were passed to the script and set the associated skip flags (if applicable)
while getopts 'bfdignh6jw:s:cupm' flag; do
    case "${flag}" in
        b) PREFER_BIN="True" ;;
        f) SKIP_FIO="True" ;;
        d) SKIP_FIO="True" ;;
        i) SKIP_IPERF="True" ;;
        g) SKIP_GEEKBENCH="True" ;;
        n) SKIP_NET="True" ;;
        h) PRINT_HELP="True" ;;
        6) GEEKBENCH_6="True" ;;
        j) JSON+="j" ;; 
        w) JSON+="w" && JSON_FILE=${OPTARG} ;;
        s) JSON+="s" && JSON_SEND=${OPTARG} ;; 
        c) SkipGovernors=true ;;
        u) SKIP_UNIXBENCH="True" ;;
        p) SKIP_PASSMARK="True" ;;
		m) SKIP_CPUMINER="True" ;;
        *) exit 1 ;;
    esac
done

# check for local fio/iperf installs
command -v fio >/dev/null 2>&1 && LOCAL_FIO=true || unset LOCAL_FIO
command -v iperf3 >/dev/null 2>&1 && LOCAL_IPERF=true || unset LOCAL_IPERF

# check for ping
command -v ping >/dev/null 2>&1 && LOCAL_PING=true || unset LOCAL_PING

# check for curl/wget
command -v curl >/dev/null 2>&1 && LOCAL_CURL=true || unset LOCAL_CURL

# test if the host has IPv4/IPv6 connectivity
[[ ! -z $LOCAL_CURL ]] && IP_CHECK_CMD="curl -s -m 4" || IP_CHECK_CMD="wget -qO- -T 4"
IPV4_CHECK=$( (ping -4 -c 1 -W 4 ipv4.google.com >/dev/null 2>&1 && echo true) || $IP_CHECK_CMD -4 icanhazip.com 2> /dev/null)
IPV6_CHECK=$( (ping -6 -c 1 -W 4 ipv6.google.com >/dev/null 2>&1 && echo true) || $IP_CHECK_CMD -6 icanhazip.com 2> /dev/null)
if [[ -z "$IPV4_CHECK" && -z "$IPV6_CHECK" ]]; then
	echo -e
	echo -e "Warning: Both IPv4 AND IPv6 connectivity were not detected. Check for DNS issues..."
fi

# Store original governor and policy
ORIGINAL_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
ORIGINAL_POLICY=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)

# print help and exit script, if help flag was passed
if [ ! -z "$PRINT_HELP" ]; then
	echo -e
	echo -e "Usage: ./yabs.sh [-flags]"
	echo -e "       curl -sL yabs.sh | bash"
	echo -e "       curl -sL yabs.sh | bash -s -- -flags"
	echo -e "       wget -qO- yabs.sh | bash"
	echo -e "       wget -qO- yabs.sh | bash -s -- -flags"
	echo -e
	echo -e "Flags:"
	echo -e "       -b : prefer pre-compiled binaries from repo over local packages"
	echo -e "       -f/d : skips the fio disk benchmark test"
	echo -e "       -i : skips the iperf network test"
	echo -e "       -g : skips the geekbench performance test"
	echo -e "       -n : skips the network information lookup and print out"
	echo -e "       -h : prints this lovely message, shows any flags you passed,"
	echo -e "            shows if fio/iperf3 local packages have been detected,"
	echo -e "            then exits"
	echo -e "       -6 : run Geekbench 6 benchmark"
	echo -e "       -j : print jsonified YABS results at conclusion of test"
	echo -e "       -w <filename> : write jsonified YABS results to disk using file name provided"
	echo -e "       -s <url> : send jsonified YABS results to URL"
	echo -e "       -c : skip governor and policy checks/changes"
	echo -e "       -u : skips the UnixBench performance test"
	echo -e "       -p : skips the PassMark PerformanceTest benchmark"
	echo -e "       -m : skips the cpuminer-multi benchmark test"
	echo -e
	echo -e "Detected Arch: $ARCH"
	echo -e
	echo -e "Detected Flags:"
	[[ ! -z $PREFER_BIN ]] && echo -e "       -b, force using precompiled binaries from repo"
	[[ ! -z $SKIP_FIO ]] && echo -e "       -f/d, skipping fio disk benchmark test"
	[[ ! -z $SKIP_IPERF ]] && echo -e "       -i, skipping iperf network test"
	[[ ! -z $SKIP_GEEKBENCH ]] && echo -e "       -g, skipping geekbench test"
	[[ ! -z $SKIP_NET ]] && echo -e "       -n, skipping network info lookup and print out"
	[[ ! -z $GEEKBENCH_6 ]] && echo -e "       running Geekbench 6"
	echo -e
	echo -e "Local Binary Check:"
	[[ -z $LOCAL_FIO ]] && echo -e "       fio not detected, will download precompiled binary" ||
		[[ -z $PREFER_BIN ]] && echo -e "       fio detected, using local package" ||
		echo -e "       fio detected, but using precompiled binary instead"
	[[ -z $LOCAL_IPERF ]] && echo -e "       iperf3 not detected, will download precompiled binary" ||
		[[ -z $PREFER_BIN ]] && echo -e "       iperf3 detected, using local package" ||
		echo -e "       iperf3 detected, but using precompiled binary instead"
	echo -e
	echo -e "Detected Connectivity:"
	[[ ! -z $IPV4_CHECK ]] && echo -e "       IPv4 connected" ||
		echo -e "       IPv4 not connected"
	[[ ! -z $IPV6_CHECK ]] && echo -e "       IPv6 connected" ||
		echo -e "       IPv6 not connected"
	echo -e
	echo -e "JSON Options:"
	[[ -z $JSON ]] && echo -e "       none"
	[[ $JSON = *j* ]] && echo -e "       printing json to screen after test"
	[[ $JSON = *w* ]] && echo -e "       writing json to file ($JSON_FILE) after test"
	[[ $JSON = *s* ]] && echo -e "       sharing json YABS results to $JSON_SEND" 
	echo -e
	echo -e "Exiting..."

	exit 0
fi

function check_cpu_governor {
    if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
        ORIGINAL_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
        echo -e "\nCurrent CPU governor: $ORIGINAL_GOVERNOR"
        if [ "$ORIGINAL_GOVERNOR" != "performance" ]; then
            echo -n "Setting CPU governor to performance... "
            echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1
            new_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
            if [ "$new_governor" == "performance" ]; then
                echo -e "✓"
            else
                echo -e "✗"
                new_governor=$ORIGINAL_GOVERNOR
            fi
        else
            echo -e "CPU governor already set to performance"
            new_governor=$ORIGINAL_GOVERNOR
        fi
    else
        echo -e "\nUnable to check CPU governor. File not found."
        new_governor="unknown"
    fi
    TESTED_GOVERNOR=$new_governor
}

function check_cpu_policy {
    if [ -f /sys/devices/system/cpu/cpufreq/policy0/scaling_governor ]; then
        ORIGINAL_POLICY=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)
        echo -e "\nCurrent CPU policy: $ORIGINAL_POLICY"
        if [ "$ORIGINAL_POLICY" != "performance" ]; then
            echo -n "Setting CPU policy to performance... "
            echo performance | tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor > /dev/null 2>&1
            new_policy=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor)
            if [ "$new_policy" == "performance" ]; then
                echo -e "✓"
            else
                echo -e "✗"
                new_policy=$ORIGINAL_POLICY
            fi
        else
            echo -e "CPU policy already set to performance"
            new_policy=$ORIGINAL_POLICY
        fi
    else
        echo -e "\nUnable to check CPU policy. File not found."
        new_policy="unknown"
    fi
    TESTED_POLICY=$new_policy
}
function restore_cpu_settings {
    if [ ! -z "$ORIGINAL_GOVERNOR" ]; then
        echo -e "\nRestoring original CPU governor..."
        echo $ORIGINAL_GOVERNOR | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
    fi
    if [ ! -z "$ORIGINAL_POLICY" ]; then
        echo -e "Restoring original CPU policy..."
        echo $ORIGINAL_POLICY | tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
    fi
}

# format_size
# Purpose: Formats raw disk and memory sizes from kibibytes (KiB) to largest unit
# Parameters:
#          1. RAW - the raw memory size (RAM/Swap) in kibibytes
# Returns:
#          Formatted memory size in KiB, MiB, GiB, or TiB
function format_size {
	RAW=$1 # mem size in KiB
	RESULT=$RAW
	local DENOM=1
	local UNIT="KiB"

	# ensure the raw value is a number, otherwise return blank
	re='^[0-9]+$'
	if ! [[ $RAW =~ $re ]] ; then
		echo "" 
		return 0
	fi

	if [ "$RAW" -ge 1073741824 ]; then
		DENOM=1073741824
		UNIT="TiB"
	elif [ "$RAW" -ge 1048576 ]; then
		DENOM=1048576
		UNIT="GiB"
	elif [ "$RAW" -ge 1024 ]; then
		DENOM=1024
		UNIT="MiB"
	fi

	# divide the raw result to get the corresponding formatted result (based on determined unit)
	RESULT=$(awk -v a="$RESULT" -v b="$DENOM" 'BEGIN { print a / b }')
	# shorten the formatted result to two decimal places (i.e. x.x)
	RESULT=$(echo $RESULT | awk -F. '{ printf "%0.1f",$1"."substr($2,1,2) }')
	# concat formatted result value with units and return result
	RESULT="$RESULT $UNIT"
	echo $RESULT
}

# gather basic system information (inc. CPU, RAM, Distro, Kernel)
echo -e 
echo -e "Basic System Information:"
echo -e "---------------------------------"
# Remove the following line to get rid of Uptime output
# UPTIME=$(uptime | awk -F'( |,|:)+' '{d=h=m=0; if ($7=="min") m=$6; else {if ($7~/^day/) {d=$6;h=$8;m=$9} else {h=$6;m=$7}}} {print d+0,"days,",h+0,"hours,",m+0,"minutes"}')
# echo -e "Uptime     : $UPTIME"
# check for local lscpu installs
command -v lscpu >/dev/null 2>&1 && LOCAL_LSCPU=true || unset LOCAL_LSCPU
if [[ $ARCH = *aarch64* || $ARCH = *arm* ]] && [[ ! -z $LOCAL_LSCPU ]]; then
	CPU_PROC=$(lscpu | grep "Model name" | sed 's/Model name: *//g')
else
	CPU_PROC=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
fi
echo -e "Processor  : $CPU_PROC"
if [[ $ARCH = *aarch64* || $ARCH = *arm* ]] && [[ ! -z $LOCAL_LSCPU ]]; then
	CPU_CORES=$(lscpu | grep "^[[:blank:]]*CPU(s):" | sed 's/CPU(s): *//g')
	CPU_FREQ=$(lscpu | grep "CPU max MHz" | sed 's/CPU max MHz: *//g' | cut -d. -f1)
	[[ -z "$CPU_FREQ" ]] && CPU_FREQ="???"
	CPU_FREQ="${CPU_FREQ} MHz"
else
	CPU_CORES=$(awk -F: '/model name/ {core++} END {print core}' /proc/cpuinfo)
	CPU_FREQ=$(awk -F: ' /cpu MHz/ {freq=$2} END {print freq " MHz"}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//' | cut -d. -f1)
fi
echo -e "CPU cores  : $CPU_CORES @ $CPU_FREQ"
TOTAL_RAM_RAW=$(free | awk 'NR==2 {print $2}')
TOTAL_RAM=$(format_size $TOTAL_RAM_RAW)
echo -e "RAM        : $TOTAL_RAM"
DISTRO=$(grep 'PRETTY_NAME' /etc/os-release | cut -d '"' -f 2 )
echo -e "Distro     : $DISTRO"
KERNEL=$(uname -r)
echo -e "Kernel     : $KERNEL"

# Call the function to check load average
check_load_average

# Check and set CPU governor and policy if not skipped
if [ -z "$SkipGovernors" ]; then
    check_cpu_governor
    check_cpu_policy
else
    # If skipping, just read the current values
    TESTED_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    TESTED_POLICY=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo "unknown")
    echo -e "\nSkipping CPU governor and policy checks/changes."
    echo -e "Current CPU governor: $TESTED_GOVERNOR"
    echo -e "Current CPU policy: $TESTED_POLICY"
fi
if [ ! -z $JSON ]; then
    UPTIME_S=$(awk '{print $1}' /proc/uptime)
    JSON_RESULT=$(cat <<EOF
{
    "version": "$YABS_VERSION",
    "time": "$TIME_START",
    "os": {
        "arch": "$ARCH",
        "distro": "$DISTRO",
        "kernel": "$KERNEL",
        "uptime": $UPTIME_S
    },
    "cpu": {
        "model": "$CPU_PROC",
        "cores": $CPU_CORES,
        "freq": "$CPU_FREQ",
        "original_governor": "$ORIGINAL_GOVERNOR",
        "original_policy": "$ORIGINAL_POLICY",
        "tested_governor": "$TESTED_GOVERNOR",
        "tested_policy": "$TESTED_POLICY"
    },
    "mem": {
        "ram": $TOTAL_RAM_RAW,
        "ram_units": "KiB"
    }
EOF
    )
fi

# create a directory in the same location that the script is being run to temporarily store YABS-related files
DATE=$(date -Iseconds | sed -e "s/:/_/g")
YABS_PATH=./$DATE
touch "$DATE.test" 2> /dev/null
# test if the user has write permissions in the current directory and exit if not
if [ ! -f "$DATE.test" ]; then
	echo -e
	echo -e "You do not have write permission in this directory. Switch to an owned directory and re-run the script.\nExiting..."
	exit 1
fi
rm "$DATE.test"
mkdir -p "$YABS_PATH"

# trap CTRL+C signals to exit script cleanly
trap catch_abort INT

# catch_abort
# Purpose: This method will catch CTRL+C signals in order to exit the script cleanly and remove
#          yabs-related files.
function catch_abort() {
	echo -e "\n** Aborting YABS. Cleaning up files...\n"
	rm -rf "$YABS_PATH"
	if [ -z "$SkipGovernors" ]; then
        restore_cpu_settings
    fi
	unset LC_ALL
	exit 0
}

# format_speed
# Purpose: This method is a convenience function to format the output of the fio disk tests which
#          always returns a result in KB/s. If result is >= 1 GB/s, use GB/s. If result is < 1 GB/s
#          and >= 1 MB/s, then use MB/s. Otherwise, use KB/s.
# Parameters:
#          1. RAW - the raw disk speed result (in KB/s)
# Returns:
#          Formatted disk speed in GB/s, MB/s, or KB/s
function format_speed {
	RAW=$1 # disk speed in KB/s
	RESULT=$RAW
	local DENOM=1
	local UNIT="KB/s"

	# ensure raw value is not null, if it is, return blank
	if [ -z "$RAW" ]; then
		echo ""
		return 0
	fi

	# check if disk speed >= 1 GB/s
	if [ "$RAW" -ge 1000000 ]; then
		DENOM=1000000
		UNIT="GB/s"
	# check if disk speed < 1 GB/s && >= 1 MB/s
	elif [ "$RAW" -ge 1000 ]; then
		DENOM=1000
		UNIT="MB/s"
	fi

	# divide the raw result to get the corresponding formatted result (based on determined unit)
	RESULT=$(awk -v a="$RESULT" -v b="$DENOM" 'BEGIN { print a / b }')
	# shorten the formatted result to two decimal places (i.e. x.xx)
	RESULT=$(echo $RESULT | awk -F. '{ printf "%0.2f",$1"."substr($2,1,2) }')
	# concat formatted result value with units and return result
	RESULT="$RESULT $UNIT"
	echo $RESULT
}

# format_iops
# Purpose: This method is a convenience function to format the output of the raw IOPS result
# Parameters:
#          1. RAW - the raw IOPS result
# Returns:
#          Formatted IOPS (i.e. 8, 123, 1.7k, 275.9k, etc.)
function format_iops {
	RAW=$1 # iops
	RESULT=$RAW

	# ensure raw value is not null, if it is, return blank
	if [ -z "$RAW" ]; then
		echo ""
		return 0
	fi

	# check if IOPS speed > 1k
	if [ "$RAW" -ge 1000 ]; then
		# divide the raw result by 1k
		RESULT=$(awk -v a="$RESULT" 'BEGIN { print a / 1000 }')
		# shorten the formatted result to one decimal place (i.e. x.x)
		RESULT=$(echo $RESULT | awk -F. '{ printf "%0.1f",$1"."substr($2,1,1) }')
		RESULT="$RESULT"k
	fi

	echo $RESULT
}

json_escape() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

function disk_test {
    if [[ "$ARCH" = "aarch64" || "$ARCH" = "arm" ]]; then
        FIO_SIZE=512M
    else
        FIO_SIZE=1G
    fi

    TEST_TYPES=("read" "write" "randread" "randwrite")

    echo "Starting disk tests..."
    
    for BS in "${BLOCK_SIZES[@]}"; do
        for TEST_TYPE in "${TEST_TYPES[@]}"; do
            echo "Running fio $TEST_TYPE disk test with $BS block size..."
            
            OUTPUT=$(timeout 60 $FIO_CMD --randrepeat=1 --ioengine=libaio --direct=1 --gtod_reduce=1 --name=$TEST_TYPE --filename="$DISK_PATH/test.fio" --bs=$BS --iodepth=64 --size=$FIO_SIZE --readwrite=$TEST_TYPE --runtime=3 --time_based --group_reporting --minimal 2>&1)
            FIO_EXIT_STATUS=$?
            
            if [ $FIO_EXIT_STATUS -eq 0 ]; then
                echo "Test completed successfully."
                DISK_TEST=$(echo "$OUTPUT" | grep $TEST_TYPE)
                
                if [ -n "$DISK_TEST" ]; then
                    if [[ "$TEST_TYPE" == *"write"* ]]; then
                        DISK_SPEED=$(echo $DISK_TEST | awk -F';' '{print $48}')
                        DISK_IOPS=$(echo $DISK_TEST | awk -F';' '{print $49}')
                    else
                        DISK_SPEED=$(echo $DISK_TEST | awk -F';' '{print $7}')
                        DISK_IOPS=$(echo $DISK_TEST | awk -F';' '{print $8}')
                    fi
                    
                    DISK_RESULTS["${BS}_${TEST_TYPE}_speed"]=$DISK_SPEED
                    DISK_RESULTS["${BS}_${TEST_TYPE}_iops"]=$DISK_IOPS

                    FORMATTED_IOPS=$(format_iops $DISK_IOPS)
                    FORMATTED_SPEED=$(format_speed $DISK_SPEED)
                    
                    echo "Results: Speed: $FORMATTED_SPEED, IOPS: $FORMATTED_IOPS"
                else
                    echo "Warning: No test results found in the output."
                fi
            else
                echo "Test failed or timed out."
            fi
            
            echo "----------------------------------------"
        done
    done
    
    echo "Disk tests completed."

    if [[ ! -z $JSON ]]; then
        DISK_JSON='"partition":'$(json_escape "$CURRENT_PARTITION")
        DISK_JSON+=',"fio":{'
        for BS in "${BLOCK_SIZES[@]}"; do
            DISK_JSON+="\"$BS\":{"
            for TEST_TYPE in "${TEST_TYPES[@]}"; do
                SPEED_KEY="${BS}_${TEST_TYPE}_speed"
                IOPS_KEY="${BS}_${TEST_TYPE}_iops"
                DISK_JSON+="\"$TEST_TYPE\":{\"speed\":${DISK_RESULTS[$SPEED_KEY]:-0},\"iops\":${DISK_RESULTS[$IOPS_KEY]:-0}},"
            done
            DISK_JSON=${DISK_JSON%,}  # Remove trailing comma
            DISK_JSON+="},"
        done
        DISK_JSON=${DISK_JSON%,}  # Remove trailing comma
        DISK_JSON+='}'
    fi

    # Print results
    echo -e "\nfio Disk Speed Tests (Partition $CURRENT_PARTITION):"
    echo -e "---------------------------------"
    for i in $(seq 0 2 $((${#BLOCK_SIZES[@]} - 1))); do
        if [ $i -gt 0 ]; then 
            printf "%-10s | %-20s | %-20s\n" "" "" ""
        fi
        printf "%-10s | %-11s %8s | %-11s %8s\n" "Block Size" "${BLOCK_SIZES[i]}" "(IOPS)" "${BLOCK_SIZES[i+1]}" "(IOPS)"
        printf "%-10s | %-11s %8s | %-11s %8s\n" "  ------" "---" "---- " "----" "---- "

        for TEST_TYPE in "${TEST_TYPES[@]}"; do
            SPEED1="${DISK_RESULTS[${BLOCK_SIZES[i]}_${TEST_TYPE}_speed]}"
            IOPS1="${DISK_RESULTS[${BLOCK_SIZES[i]}_${TEST_TYPE}_iops]}"
            SPEED2="${DISK_RESULTS[${BLOCK_SIZES[i+1]}_${TEST_TYPE}_speed]}"
            IOPS2="${DISK_RESULTS[${BLOCK_SIZES[i+1]}_${TEST_TYPE}_iops]}"
            
            TEST_NAME=$(tr '[:lower:]' '[:upper:]' <<< ${TEST_TYPE:0:1})${TEST_TYPE:1}
            printf "%-10s | %-11s %8s | %-11s %8s\n" "$TEST_NAME" \
                "$(format_speed "$SPEED1")" "($IOPS1)" \
                "$(format_speed "$SPEED2")" "($IOPS2)"
        done
    done
}

# dd_test
# Purpose: This method is invoked if the fio disk test failed. dd sequential speed tests are
#          not indiciative or real-world results, however, some form of disk speed measure 
#          is better than nothing.
# Parameters:
#          - (none)
function dd_test {
	I=0
	DISK_WRITE_TEST_RES=()
	DISK_READ_TEST_RES=()
	DISK_WRITE_TEST_AVG=0
	DISK_READ_TEST_AVG=0

	# run the disk speed tests (write and read) thrice over
	while [ $I -lt 3 ]
	do
		# write test using dd, "direct" flag is used to test direct I/O for data being stored to disk
		DISK_WRITE_TEST=$(dd if=/dev/zero of="$DISK_PATH/$DATE.test" bs=64k count=16k oflag=direct |& grep copied | awk '{ print $(NF-1) " " $(NF)}')
		VAL=$(echo $DISK_WRITE_TEST | cut -d " " -f 1)
		[[ "$DISK_WRITE_TEST" == *"GB"* ]] && VAL=$(awk -v a="$VAL" 'BEGIN { print a * 1000 }')
		DISK_WRITE_TEST_RES+=( "$DISK_WRITE_TEST" )
		DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" -v b="$VAL" 'BEGIN { print a + b }')

		# read test using dd using the 1G file written during the write test
		DISK_READ_TEST=$(dd if="$DISK_PATH/$DATE.test" of=/dev/null bs=8k |& grep copied | awk '{ print $(NF-1) " " $(NF)}')
		VAL=$(echo $DISK_READ_TEST | cut -d " " -f 1)
		[[ "$DISK_READ_TEST" == *"GB"* ]] && VAL=$(awk -v a="$VAL" 'BEGIN { print a * 1000 }')
		DISK_READ_TEST_RES+=( "$DISK_READ_TEST" )
		DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" -v b="$VAL" 'BEGIN { print a + b }')

		I=$(( $I + 1 ))
	done
	# calculate the write and read speed averages using the results from the three runs
	DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" 'BEGIN { print a / 3 }')
	DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" 'BEGIN { print a / 3 }')
}

# check if disk performance is being tested and the host has required space (2G)
AVAIL_SPACE=$(df -k . | awk 'NR==2{print $4}')
if [[ -z "$SKIP_FIO" && "$AVAIL_SPACE" -lt 2097152 && "$ARCH" != "aarch64" && "$ARCH" != "arm" ]]; then # 2GB = 2097152KB
	echo -e "\nLess than 2GB of space available. Skipping disk test..."
elif [[ -z "$SKIP_FIO" && "$AVAIL_SPACE" -lt 524288 && ("$ARCH" = "aarch64" || "$ARCH" = "arm") ]]; then # 512MB = 524288KB
	echo -e "\nLess than 512MB of space available. Skipping disk test..."
# if the skip disk flag was set, skip the disk performance test, otherwise test disk performance
elif [ -z "$SKIP_FIO" ]; then
	# Perform ZFS filesystem detection and determine if we have enough free space according to spa_asize_inflation
	ZFSCHECK="/sys/module/zfs/parameters/spa_asize_inflation"
	if [[ -f "$ZFSCHECK" ]];then
		mul_spa=$((($(cat /sys/module/zfs/parameters/spa_asize_inflation)*2)))
		warning=0
		poss=()

		for pathls in $(df -Th | awk '{print $7}' | tail -n +2)
		do
			if [[ "${PWD##$pathls}" != "${PWD}" ]]; then
				poss+=("$pathls")
			fi
		done

		long=""
		m=-1
		for x in ${poss[@]}
		do
			if [ ${#x} -gt $m ];then
				m=${#x}
				long=$x
			fi
		done

		size_b=$(df -Th | grep -w $long | grep -i zfs | awk '{print $5}' | tail -c -2 | head -c 1)
		free_space=$(df -Th | grep -w $long | grep -i zfs | awk '{print $5}' | head -c -2)

		if [[ $size_b == 'T' ]]; then
			free_space=$(awk "BEGIN {print int($free_space * 1024)}")
			size_b='G'
		fi

		if [[ $(df -Th | grep -w $long) == *"zfs"* ]];then

			if [[ $size_b == 'G' ]]; then
				if ((free_space < mul_spa)); then
					warning=1
				fi
			else
				warning=1
			fi

		fi

		if [[ $warning -eq 1 ]];then
			echo -en "\nWarning! You are running YABS on a ZFS Filesystem and your disk space is too low for the fio test. Your test results will be inaccurate. You need at least $mul_spa GB free in order to complete this test accurately. For more information, please see https://github.com/masonr/yet-another-bench-script/issues/13\n"
		fi
	fi
	
	echo -en "\nPreparing system for disk tests..."

	# create temp directory to store disk write/read test files
	DISK_PATH=$YABS_PATH/disk
	mkdir -p "$DISK_PATH"

	if [[ -z "$PREFER_BIN" && ! -z "$LOCAL_FIO" ]]; then # local fio has been detected, use instead of pre-compiled binary
		FIO_CMD=fio
	else
		# download fio binary
		if [[ ! -z $LOCAL_CURL ]]; then
			curl -s --connect-timeout 5 --retry 5 --retry-delay 0 https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/bin/fio/fio_$ARCH -o "$DISK_PATH/fio"
		else
			wget -q -T 5 -t 5 -w 0 https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/bin/fio/fio_$ARCH -O "$DISK_PATH/fio"
		fi

		if [ ! -f "$DISK_PATH/fio" ]; then # ensure fio binary download successfully
			echo -en "\r\033[0K"
			echo -e "Fio binary download failed. Running dd test as fallback...."
			DD_FALLBACK=True
		else
			chmod +x "$DISK_PATH/fio"
			FIO_CMD=$DISK_PATH/fio
		fi
	fi

	if [ -z "$DD_FALLBACK" ]; then # if not falling back on dd tests, run fio test
		echo -en "\r\033[0K"

		# disk block sizes to evaluate
		BLOCK_SIZES=( "4k" "8k" "64k" "512k" "1m" "16m" )

		# execute disk performance test
		disk_test "${BLOCK_SIZES[@]}"
		
		CURRENT_PARTITION=$(df -P . 2>/dev/null | tail -1 | cut -d' ' -f 1)
		if [[ ! -z $JSON ]]; then
    CURRENT_PARTITION=${CURRENT_PARTITION:-""}
    DISK_JSON='"partition":'$(json_escape "$CURRENT_PARTITION")
    DISK_JSON+=',"fio":{'
    for BS in "${BLOCK_SIZES[@]}"; do
        DISK_JSON+="\"$BS\":{"
        for TEST_TYPE in "${TEST_TYPES[@]}"; do
            SPEED_KEY="${BS}_${TEST_TYPE}_speed"
            IOPS_KEY="${BS}_${TEST_TYPE}_iops"
            DISK_JSON+="\"$TEST_TYPE\":{\"speed\":${DISK_RESULTS[$SPEED_KEY]:-0},\"iops\":${DISK_RESULTS[$IOPS_KEY]:-0}},"
        done
        DISK_JSON=${DISK_JSON%,}  # Remove trailing comma
        DISK_JSON+="},"
    done
    DISK_JSON=${DISK_JSON%,}  # Remove trailing comma
    DISK_JSON+='}'
fi	fi

	if [[ ! -z "$DD_FALLBACK" || ${#DISK_RESULTS[@]} -eq 0 ]]; then # fio download failed or test was killed or returned an error, run dd test instead
		if [ -z "$DD_FALLBACK" ]; then # print error notice if ended up here due to fio error
			echo -e "fio disk speed tests failed. Run manually to determine cause.\nRunning dd test as fallback..."
		fi

		dd_test

		# format the speed averages by converting to GB/s if > 1000 MB/s
		if [ $(echo $DISK_WRITE_TEST_AVG | cut -d "." -f 1) -ge 1000 ]; then
			DISK_WRITE_TEST_AVG=$(awk -v a="$DISK_WRITE_TEST_AVG" 'BEGIN { print a / 1000 }')
			DISK_WRITE_TEST_UNIT="GB/s"
		else
			DISK_WRITE_TEST_UNIT="MB/s"
		fi
		if [ $(echo $DISK_READ_TEST_AVG | cut -d "." -f 1) -ge 1000 ]; then
			DISK_READ_TEST_AVG=$(awk -v a="$DISK_READ_TEST_AVG" 'BEGIN { print a / 1000 }')
			DISK_READ_TEST_UNIT="GB/s"
		else
			DISK_READ_TEST_UNIT="MB/s"
		fi

		# print dd sequential disk speed test results
		echo -e
		echo -e "dd Sequential Disk Speed Tests:"
		echo -e "---------------------------------"
		printf "%-6s | %-6s %-4s | %-6s %-4s | %-6s %-4s | %-6s %-4s\n" "" "Test 1" "" "Test 2" ""  "Test 3" "" "Avg" ""
		printf "%-6s | %-6s %-4s | %-6s %-4s | %-6s %-4s | %-6s %-4s\n"
		printf "%-6s | %-11s | %-11s | %-11s | %-6.2f %-4s\n" "Write" "${DISK_WRITE_TEST_RES[0]}" "${DISK_WRITE_TEST_RES[1]}" "${DISK_WRITE_TEST_RES[2]}" "${DISK_WRITE_TEST_AVG}" "${DISK_WRITE_TEST_UNIT}" 
		printf "%-6s | %-11s | %-11s | %-11s | %-6.2f %-4s\n" "Read" "${DISK_READ_TEST_RES[0]}" "${DISK_READ_TEST_RES[1]}" "${DISK_READ_TEST_RES[2]}" "${DISK_READ_TEST_AVG}" "${DISK_READ_TEST_UNIT}" 
	else # fio tests completed successfully, print results
		CURRENT_PARTITION=$(df -P . 2>/dev/null | tail -1 | cut -d' ' -f 1)
		if [[ ! -z $JSON ]]; then
			if [ ! -z "$DISK_JSON" ]; then
				JSON_RESULT+=",$DISK_JSON"
			else
				echo "WARNING: Disk test results not available for JSON output."
				JSON_RESULT+=',"partition":"","fio":{}'
			fi
		fi

		# print disk speed test results
		echo -e "fio Disk Speed Tests (Partition $CURRENT_PARTITION):"
		echo -e "---------------------------------"

		# Print results
		for i in $(seq 0 2 $((${#BLOCK_SIZES[@]} - 1))); do
			if [ $i -gt 0 ]; then 
				printf "%-10s | %-20s | %-20s\n" "" "" ""
			fi
			printf "%-10s | %-11s %8s | %-11s %8s\n" "Block Size" "${BLOCK_SIZES[i]}" "(IOPS)" "${BLOCK_SIZES[i+1]}" "(IOPS)"
			printf "%-10s | %-11s %8s | %-11s %8s\n" "  ------" "---" "---- " "----" "---- "

			for TEST_TYPE in "${TEST_TYPES[@]}"; do
				SPEED1="${DISK_RESULTS[${BLOCK_SIZES[i]}_${TEST_TYPE}_speed]}"
				IOPS1="${DISK_RESULTS[${BLOCK_SIZES[i]}_${TEST_TYPE}_iops]}"
				SPEED2="${DISK_RESULTS[${BLOCK_SIZES[i+1]}_${TEST_TYPE}_speed]}"
				IOPS2="${DISK_RESULTS[${BLOCK_SIZES[i+1]}_${TEST_TYPE}_iops]}"
				
				TEST_NAME=$(tr '[:lower:]' '[:upper:]' <<< ${TEST_TYPE:0:1})${TEST_TYPE:1}
				printf "%-10s | %-11s %8s | %-11s %8s\n" "$TEST_NAME" \
					"$(format_speed "$SPEED1")" "($IOPS1)" \
					"$(format_speed "$SPEED2")" "($IOPS2)"
			done
		done
	fi
fi

# iperf_test
# Purpose: This method is designed to test the network performance of the host by executing an
#          iperf3 test to/from the public iperf server passed to the function. Both directions 
#          (send and receive) are tested.
# Parameters:
#          1. URL - URL/domain name of the iperf server
#          2. PORTS - the range of ports on which the iperf server operates
#          3. HOST - the friendly name of the iperf server host/owner
#          4. FLAGS - any flags that should be passed to the iperf command
function iperf_test {
	URL=$1
	PORTS=$2
	HOST=$3
	FLAGS=$4
	
	# attempt the iperf send test 3 times, allowing for a slot to become available on the
	#   server or to throw out any bad/error results
	I=1
	while [ $I -le 3 ]
	do
		echo -en "Performing $MODE iperf3 send test to $HOST (Attempt #$I of 3)..."
		# select a random iperf port from the range provided
		PORT=$(shuf -i $PORTS -n 1)
		# run the iperf test sending data from the host to the iperf server; includes
		#   a timeout of 15s in case the iperf server is not responding; uses 8 parallel
		#   threads for the network test
		IPERF_RUN_SEND="$(timeout 15 $IPERF_CMD $FLAGS -c "$URL" -p $PORT -P 8 2> /dev/null)"
		# check if iperf exited cleanly and did not return an error
		if [[ "$IPERF_RUN_SEND" == *"receiver"* && "$IPERF_RUN_SEND" != *"error"* ]]; then
			# test did not result in an error, parse speed result
			SPEED=$(echo "${IPERF_RUN_SEND}" | grep SUM | grep receiver | awk '{ print $6 }')
			# if speed result is blank or bad (0.00), rerun, otherwise set counter to exit loop
			[[ -z $SPEED || "$SPEED" == "0.00" ]] && I=$(( $I + 1 )) || I=11
		else
			# if iperf server is not responding, set counter to exit, otherwise increment, sleep, and rerun
			[[ "$IPERF_RUN_SEND" == *"unable to connect"* ]] && I=11 || I=$(( $I + 1 )) && sleep 2
		fi
		echo -en "\r\033[0K"
	done

	# small sleep necessary to give iperf server a breather to get ready for a new test
	sleep 1

	# attempt the iperf receive test 3 times, allowing for a slot to become available on
	#   the server or to throw out any bad/error results
	J=1
	while [ $J -le 3 ]
	do
		echo -n "Performing $MODE iperf3 recv test from $HOST (Attempt #$J of 3)..."
		# select a random iperf port from the range provided
		PORT=$(shuf -i $PORTS -n 1)
		# run the iperf test receiving data from the iperf server to the host; includes
		#   a timeout of 15s in case the iperf server is not responding; uses 8 parallel
		#   threads for the network test
		IPERF_RUN_RECV="$(timeout 15 $IPERF_CMD $FLAGS -c "$URL" -p $PORT -P 8 -R 2> /dev/null)"
		# check if iperf exited cleanly and did not return an error
		if [[ "$IPERF_RUN_RECV" == *"receiver"* && "$IPERF_RUN_RECV" != *"error"* ]]; then
			# test did not result in an error, parse speed result
			SPEED=$(echo "${IPERF_RUN_RECV}" | grep SUM | grep receiver | awk '{ print $6 }')
			# if speed result is blank or bad (0.00), rerun, otherwise set counter to exit loop
			[[ -z $SPEED || "$SPEED" == "0.00" ]] && J=$(( $J + 1 )) || J=11
		else
			# if iperf server is not responding, set counter to exit, otherwise increment, sleep, and rerun
			[[ "$IPERF_RUN_RECV" == *"unable to connect"* ]] && J=11 || J=$(( $J + 1 )) && sleep 2
		fi
		echo -en "\r\033[0K"
	done
	
	# Run a latency test via ping -c1 command -> will return "xx.x ms"
	[[ ! -z $LOCAL_PING ]] && LATENCY_RUN="$(ping -c1 $URL 2>/dev/null | grep -o 'time=.*' | sed s/'time='//)" 
	[[ -z $LATENCY_RUN ]] && LATENCY_RUN="--"

	# parse the resulting send and receive speed results
	IPERF_SENDRESULT="$(echo "${IPERF_RUN_SEND}" | grep SUM | grep receiver)"
	IPERF_RECVRESULT="$(echo "${IPERF_RUN_RECV}" | grep SUM | grep receiver)"
	LATENCY_RESULT="$(echo "${LATENCY_RUN}")"
}

# launch_iperf
# Purpose: This method is designed to facilitate the execution of iperf network speed tests to
#          each public iperf server in the iperf server locations array.
# Parameters:
#          1. MODE - indicates the type of iperf tests to run (IPv4 or IPv6)
function launch_iperf {
	MODE=$1
	[[ "$MODE" == *"IPv6"* ]] && IPERF_FLAGS="-6" || IPERF_FLAGS="-4"

	# print iperf3 network speed results as they are completed
	echo -e
	echo -e "iperf3 Network Speed Tests ($MODE):"
	echo -e "---------------------------------"
	printf "%-15s | %-25s | %-15s | %-15s | %-15s\n" "Provider" "Location (Link)" "Send Speed" "Recv Speed" "Ping"
	printf "%-15s | %-25s | %-15s | %-15s | %-15s\n" "-----" "-----" "----" "----" "----"
	
	# loop through iperf locations array to run iperf test using each public iperf server
	for (( i = 0; i < IPERF_LOCS_NUM; i++ )); do
		# test if the current iperf location supports the network mode being tested (IPv4/IPv6)
		if [[ "${IPERF_LOCS[i*5+4]}" == *"$MODE"* ]]; then
			# call the iperf_test function passing the required parameters
			iperf_test "${IPERF_LOCS[i*5]}" "${IPERF_LOCS[i*5+1]}" "${IPERF_LOCS[i*5+2]}" "$IPERF_FLAGS"
			# parse the send and receive speed results
			IPERF_SENDRESULT_VAL=$(echo $IPERF_SENDRESULT | awk '{ print $6 }')
			IPERF_SENDRESULT_UNIT=$(echo $IPERF_SENDRESULT | awk '{ print $7 }')
			IPERF_RECVRESULT_VAL=$(echo $IPERF_RECVRESULT | awk '{ print $6 }')
			IPERF_RECVRESULT_UNIT=$(echo $IPERF_RECVRESULT | awk '{ print $7 }')
			LATENCY_VAL=$(echo $LATENCY_RESULT)
			# if the results are blank, then the server is "busy" and being overutilized
			[[ -z $IPERF_SENDRESULT_VAL || "$IPERF_SENDRESULT_VAL" == *"0.00"* ]] && IPERF_SENDRESULT_VAL="busy" && IPERF_SENDRESULT_UNIT=""
			[[ -z $IPERF_RECVRESULT_VAL || "$IPERF_RECVRESULT_VAL" == *"0.00"* ]] && IPERF_RECVRESULT_VAL="busy" && IPERF_RECVRESULT_UNIT=""
			# print the speed results for the iperf location currently being evaluated
			printf "%-15s | %-25s | %-15s | %-15s | %-15s\n" "${IPERF_LOCS[i*5+2]}" "${IPERF_LOCS[i*5+3]}" "$IPERF_SENDRESULT_VAL $IPERF_SENDRESULT_UNIT" "$IPERF_RECVRESULT_VAL $IPERF_RECVRESULT_UNIT" "$LATENCY_VAL"
			if [ ! -z $JSON ]; then
				JSON_RESULT+='{"mode":"'$MODE'","provider":"'${IPERF_LOCS[i*5+2]}'","loc":"'${IPERF_LOCS[i*5+3]}
				JSON_RESULT+='","send":"'$IPERF_SENDRESULT_VAL' '$IPERF_SENDRESULT_UNIT'","recv":"'$IPERF_RECVRESULT_VAL' '$IPERF_RECVRESULT_UNIT'","latency":"'$LATENCY_VAL'"},'
			fi
		fi
	done
}

# if the skip iperf flag was set, skip the network performance test, otherwise test network performance
if [ -z "$SKIP_IPERF" ]; then

	if [[ -z "$PREFER_BIN" && ! -z "$LOCAL_IPERF" ]]; then # local iperf has been detected, use instead of pre-compiled binary
		IPERF_CMD=iperf3
	else
		# create a temp directory to house the required iperf binary and library
		IPERF_PATH=$YABS_PATH/iperf
		mkdir -p "$IPERF_PATH"

		# download iperf3 binary
		if [[ ! -z $LOCAL_CURL ]]; then
			curl -s --connect-timeout 5 --retry 5 --retry-delay 0 https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/bin/iperf/iperf3_$ARCH -o "$IPERF_PATH/iperf3"
		else
			wget -q -T 5 -t 5 -w 0 https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/bin/iperf/iperf3_$ARCH -O "$IPERF_PATH/iperf3"
		fi

		if [ ! -f "$IPERF_PATH/iperf3" ]; then # ensure iperf3 binary downloaded successfully
			IPERF_DL_FAIL=True
		else
			chmod +x "$IPERF_PATH/iperf3"
			IPERF_CMD=$IPERF_PATH/iperf3
		fi
	fi
	
	# array containing all currently available iperf3 public servers to use for the network test
	# format: "1" "2" "3" "4" "5" \
	#   1. domain name of the iperf server
	#   2. range of ports that the iperf server is running on (lowest-highest)
	#   3. friendly name of the host/owner of the iperf server
	#   4. location and advertised speed link of the iperf server
	#   5. network modes supported by the iperf server (IPv4 = IPv4-only, IPv4|IPv6 = IPv4 + IPv6, etc.)
	IPERF_LOCS=( \
		"192.168.1.3" "5201-5201" "home" "Stockholm, SE (1G)" "IPv4"
	)

	# get the total number of iperf locations (total array size divided by 5 since each location has 5 elements)
	IPERF_LOCS_NUM=${#IPERF_LOCS[@]}
	IPERF_LOCS_NUM=$((IPERF_LOCS_NUM / 5))
	
	if [ -z "$IPERF_DL_FAIL" ]; then
		[[ ! -z $JSON ]] && JSON_RESULT+=',"iperf":['
		# check if the host has IPv4 connectivity, if so, run iperf3 IPv4 tests
		[ ! -z "$IPV4_CHECK" ] && launch_iperf "IPv4"
		# check if the host has IPv6 connectivity, if so, run iperf3 IPv6 tests
		[ ! -z "$IPV6_CHECK" ] && launch_iperf "IPv6"
		[[ ! -z $JSON ]] && JSON_RESULT=${JSON_RESULT::${#JSON_RESULT}-1} && JSON_RESULT+=']'
	else
		echo -e "\niperf3 binary download failed. Skipping iperf network tests..."
	fi
fi

# launch_geekbench
# Purpose: This method is designed to run the Primate Labs' Geekbench 6 Cross-Platform Benchmark utility
# Parameters:
#          1. VERSION - indicates which Geekbench version to run
function launch_geekbench {
    VERSION=$1

    # create a temp directory to house all geekbench files
    GEEKBENCH_PATH=$YABS_PATH/geekbench_$VERSION
    mkdir -p "$GEEKBENCH_PATH"

    GB_URL=""
    GB_CMD=""
    GB_RUN=""

    # check for curl vs wget
    [[ ! -z $LOCAL_CURL ]] && DL_CMD="curl -s" || DL_CMD="wget -qO-"

    if [[ $VERSION == *6* ]]; then # Geekbench v6
        if [[ $ARCH = *x86* ]]; then
            echo -e "\nGeekbench 6 cannot run on 32-bit architectures. Skipping test."
        else
            [[ $ARCH = *aarch64* || $ARCH = *arm* ]] && GB_URL="https://cdn.geekbench.com/Geekbench-6.3.0-LinuxARMPreview.tar.gz" \
                || GB_URL="https://cdn.geekbench.com/Geekbench-6.3.0-Linux.tar.gz"
            GB_CMD="geekbench6"
            GB_RUN="True"
        fi
    fi

    if [[ $GB_RUN == *True* ]]; then # run GB test
        echo -en "\nRunning GB$VERSION benchmark test... *cue elevator music*"

        # check for local geekbench installed
        if command -v "$GB_CMD" &>/dev/null; then
            GEEKBENCH_PATH=$(dirname "$(command -v "$GB_CMD")")
        else
            # download the desired Geekbench tarball and extract to geekbench temp directory
            $DL_CMD $GB_URL | tar xz --strip-components=1 -C "$GEEKBENCH_PATH" &>/dev/null
        fi

        # unlock if license file detected
        test -f "geekbench.license" && "$GEEKBENCH_PATH/$GB_CMD" --unlock $(cat geekbench.license) > /dev/null 2>&1

        # run the Geekbench test and grep the test results URL given at the end of the test
        GEEKBENCH_TEST=$("$GEEKBENCH_PATH/$GB_CMD" --upload 2>/dev/null | grep "https://browser")

        # ensure the test ran successfully
        if [ -z "$GEEKBENCH_TEST" ]; then
            # detect if CentOS 7 and print a more helpful error message
            if grep -q "CentOS Linux 7" /etc/os-release; then
                echo -e "\r\033[0K CentOS 7 and Geekbench have known issues relating to glibc (see issue #71 for details)"
            fi
            if [[ -z "$IPV4_CHECK" ]]; then
                # Geekbench test failed to download because host lacks IPv4 (cdn.geekbench.com = IPv4 only)
                echo -e "\r\033[0KGeekbench releases can only be downloaded over IPv4. FTP the Geekbench files and run manually."
            elif [[ $VERSION != *4* && $TOTAL_RAM_RAW -le 1048576 ]]; then
                # Geekbench 5/6 test failed with low memory (<=1GB)
                echo -e "\r\033[0KGeekbench test failed and low memory was detected. Add at least 1GB of SWAP or use GB4 instead (higher compatibility with low memory systems)."
            elif [[ $ARCH != *x86* ]]; then
                # if the Geekbench test failed for any other reason, exit cleanly and print error message
                echo -e "\r\033[0KGeekbench $VERSION test failed. Run manually to determine cause."
            fi
        else
            # if the Geekbench test succeeded, parse the test results URL
            GEEKBENCH_URL=$(echo -e $GEEKBENCH_TEST | head -1)
            GEEKBENCH_URL_CLAIM=$(echo $GEEKBENCH_URL | awk '{ print $2 }')
            GEEKBENCH_URL=$(echo $GEEKBENCH_URL | awk '{ print $1 }')
            # sleep a bit to wait for results to be made available on the geekbench website
            sleep 10
            # parse the public results page for the single and multi core geekbench scores
            [[ $VERSION == *4* ]] && GEEKBENCH_SCORES=$($DL_CMD $GEEKBENCH_URL | grep "span class='score'") || \
                GEEKBENCH_SCORES=$($DL_CMD $GEEKBENCH_URL | grep "div class='score'")
                
            GEEKBENCH_SCORES_SINGLE=$(echo $GEEKBENCH_SCORES | awk -v FS="(>|<)" '{ print $3 }')
            GEEKBENCH_SCORES_MULTI=$(echo $GEEKBENCH_SCORES | awk -v FS="(>|<)" '{ print $7 }')
        
            # print the Geekbench results
            echo -en "\r\033[0K"
            echo -e "Geekbench $VERSION Benchmark Test:"
            echo -e "---------------------------------"
            printf "%-15s | %-30s\n" "Test" "Value"
            printf "%-15s | %-30s\n"
            printf "%-15s | %-30s\n" "Single Core" "$GEEKBENCH_SCORES_SINGLE"
            printf "%-15s | %-30s\n" "Multi Core" "$GEEKBENCH_SCORES_MULTI"
            printf "%-15s | %-30s\n" "Full Test" "$GEEKBENCH_URL"

            if [ ! -z $JSON ]; then
                JSON_RESULT+='{"version":'$VERSION',"single":'$GEEKBENCH_SCORES_SINGLE',"multi":'$GEEKBENCH_SCORES_MULTI
                JSON_RESULT+=',"url":"'$GEEKBENCH_URL'"},'
            fi

            # write the geekbench claim URL to a file so the user can add the results to their profile (if desired)
            [ ! -z "$GEEKBENCH_URL_CLAIM" ] && echo -e "$GEEKBENCH_URL_CLAIM" >> geekbench_claim.url 2> /dev/null
        fi
    fi
}

# if the skip geekbench flag was set, skip the system performance test, otherwise test system performance
if [ -z "$SKIP_GEEKBENCH" ]; then
    [[ ! -z $JSON ]] && JSON_RESULT+=',"geekbench":['
    if [[ $GEEKBENCH_6 == *True* ]]; then
        launch_geekbench 6
    fi
    [[ ! -z $JSON ]] && [[ $(echo -n $JSON_RESULT | tail -c 1) == ',' ]] && JSON_RESULT=${JSON_RESULT::${#JSON_RESULT}-1}
    [[ ! -z $JSON ]] && JSON_RESULT+=']'
fi

function run_unixbench {
    echo -e "\nRunning UnixBench performance test..."
    
    # Create UnixBench directory
    UNIXBENCH_PATH=$YABS_PATH/byte-unixbench
    mkdir -p "$UNIXBENCH_PATH"
    
    # Clone UnixBench repository
    git clone https://github.com/kdlucas/byte-unixbench "$UNIXBENCH_PATH"
    
    if [ ! -d "$UNIXBENCH_PATH/UnixBench" ]; then
        echo "Failed to clone UnixBench repository. Skipping UnixBench test."
        return
    fi
    
    # Run UnixBench
    pushd "$UNIXBENCH_PATH/UnixBench" > /dev/null
    ./Run -i $UNIXBENCH_NUMBER_OF_RUNS > unixbench_results.txt
    popd > /dev/null
    
    # Parse results
    UNIXBENCH_OUTPUT=$(cat "$UNIXBENCH_PATH/UnixBench/unixbench_results.txt")
    
    # Extract single-core and multi-core results
    SINGLE_CORE_RESULTS=$(echo "$UNIXBENCH_OUTPUT" | sed -n '/running 1 parallel copy of tests/,/running [0-9]* parallel copies of tests/p')
    MULTI_CORE_RESULTS=$(echo "$UNIXBENCH_OUTPUT" | sed -n '/running [0-9]* parallel copies of tests/,$p')
    
    # Function to parse results and generate JSON
    parse_results() {
        local results="$1"
        local json=""
        
        while IFS= read -r line; do
            if [[ $line =~ ^([^0-9]+)[[:space:]]+([0-9.]+)[[:space:]]+([0-9.]+)[[:space:]]+([0-9.]+)$ ]]; then
                test_name="${BASH_REMATCH[1]}"
                baseline="${BASH_REMATCH[2]}"
                result="${BASH_REMATCH[3]}"
                index="${BASH_REMATCH[4]}"
                
                json+="\"$test_name\": {\"baseline\": $baseline, \"result\": $result, \"index\": $index},"
            elif [[ $line =~ ^System[[:space:]]Benchmarks[[:space:]]Index[[:space:]]Score[[:space:]]+([0-9.]+)$ ]]; then
                overall_score="${BASH_REMATCH[1]}"
                json+="\"Overall Index Score\": $overall_score"
            fi
        done <<< "$results"
        
        echo "{$json}"
    }
    
    # Generate JSON for single-core and multi-core results
    SINGLE_CORE_JSON=$(parse_results "$SINGLE_CORE_RESULTS")
    MULTI_CORE_JSON=$(parse_results "$MULTI_CORE_RESULTS")
    
    # Combine results into final JSON
    UNIXBENCH_JSON="{\"unixbench\": {\"single-core\": {\"System Benchmarks Index\": $SINGLE_CORE_JSON}, \"multi-core\": {\"System Benchmarks Index\": $MULTI_CORE_JSON}}}"
    
    # Add UnixBench results to the main JSON result
    if [ ! -z $JSON ]; then
        JSON_RESULT+=",$(echo $UNIXBENCH_JSON | sed 's/^{//;s/}$//')"
    fi
    
    # Print results
    echo -e "\nUnixBench Results:"
    echo -e "---------------------------------"
    echo -e "Single-core Overall Index Score: $(echo $SINGLE_CORE_JSON | jq -r '."Overall Index Score"')"
    echo -e "Multi-core Overall Index Score: $(echo $MULTI_CORE_JSON | jq -r '."Overall Index Score"')"
    echo -e "\nFor detailed results, please check the JSON output."
}

# if the skip unixbench flag was set, skip the unixbench performance test, otherwise test unixbench performance
if [ -z "$SKIP_UNIXBENCH" ]; then
    run_unixbench
fi

# Add a function to run PassMark PerformanceTest
function run_passmark {
    echo -e "\nRunning PassMark PerformanceTest..."
    
    PASSMARK_PATH=$YABS_PATH/passmark
    mkdir -p "$PASSMARK_PATH"
    
    # Determine the correct download URL based on architecture
    if [[ $ARCH == "aarch64" || $ARCH == "arm64" ]]; then
        PASSMARK_URL="https://www.passmark.com/downloads/pt_linux_arm64.zip"
        PASSMARK_EXE="pt_linux_arm64"
    elif [[ $ARCH == "x86_64" || $ARCH == "x64" ]]; then
        PASSMARK_URL="https://www.passmark.com/downloads/pt_linux_x64.zip"
        PASSMARK_EXE="pt_linux_x64"
    else
        echo "Unsupported architecture for PassMark PerformanceTest. Skipping test."
        return
    fi
    
    # Download and extract PassMark PerformanceTest
    if [[ ! -z $LOCAL_CURL ]]; then
        curl -s -L "$PASSMARK_URL" -o "$PASSMARK_PATH/passmark.zip"
    else
        wget -q "$PASSMARK_URL" -O "$PASSMARK_PATH/passmark.zip"
    fi
    
    unzip -q "$PASSMARK_PATH/passmark.zip" -d "$PASSMARK_PATH"
    
    if [ ! -f "$PASSMARK_PATH/PerformanceTest/$PASSMARK_EXE" ]; then
        echo "Failed to download or extract PassMark PerformanceTest. Skipping test."
        return
    fi
    
    # Run PassMark PerformanceTest
    pushd "$PASSMARK_PATH/PerformanceTest" > /dev/null
    ./$PASSMARK_EXE -r $PERFORMANCETEST_AUTORUN_VALUE -d $PERFORMANCETEST_DURATION
    popd > /dev/null
    
    # Parse results
    PASSMARK_RESULTS=$(cat "$PASSMARK_PATH/PerformanceTest/results_all.yml")
    
    # Extract and format results
    parse_passmark_results
    
    # Print results
    echo -e "\nPassMark PerformanceTest Results:"
    echo -e "---------------------------------"
    echo -e "CPU Mark: $PASSMARK_CPU_MARK"
    echo -e "Memory Mark: $PASSMARK_MEMORY_MARK"
    echo -e "\nFor detailed results, please check the JSON output."
}

function parse_passmark_results {
    # Extract results using awk
    PASSMARK_RESULTS=$(awk '/Results:/,/SystemInformation:/' "$PASSMARK_PATH/PerformanceTest/results_all.yml")
    
    # Parse individual results
    PASSMARK_CPU_MARK=$(echo "$PASSMARK_RESULTS" | awk '/SUMM_CPU:/ {print int($2)}')
    PASSMARK_MEMORY_MARK=$(echo "$PASSMARK_RESULTS" | awk '/SUMM_ME:/ {print int($2)}')
    
    # Create JSON array for PassMark results
    PASSMARK_JSON='"passmark":{'
    PASSMARK_JSON+='"CPU Mark":'$PASSMARK_CPU_MARK
    PASSMARK_JSON+=',"Memory Mark":'$PASSMARK_MEMORY_MARK
    PASSMARK_JSON+=',"CPU":{
        "Integer Math":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_INTEGER_MATH:/ {print int($2)}')"',
        "Floating Point Math":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_FLOATINGPOINT_MATH:/ {print int($2)}')"',
        "Prime Numbers":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_PRIME:/ {print int($2)}')"',
        "Sorting":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_SORTING:/ {print int($2)}')"',
        "Encryption":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_ENCRYPTION:/ {print int($2)}')"',
        "Compression":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_COMPRESSION:/ {print int($2)}')"',
        "Single Thread":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_SINGLETHREAD:/ {print int($2)}')"',
        "Physics":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_PHYSICS:/ {print int($2)}')"'
    }'
    PASSMARK_JSON+=',"Memory":{
        "Database Operations":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_ALLOC_S:/ {print int($2)}')"',
        "Read Cached":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_READ_S:/ {print int($2)}')"',
        "Read Uncached":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_READ_L:/ {print int($2)}')"',
        "Write":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_WRITE:/ {print int($2)}')"',
        "Available RAM":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_LARGE:/ {print int($2)}')"',
        "Latency":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_LATENCY:/ {print int($2)}')"',
        "Threaded":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_THREADED:/ {print int($2)}')"'
    }'
    PASSMARK_JSON+='}'
    
    # Add PassMark results to the main JSON result
    if [ ! -z $JSON ]; then
        JSON_RESULT+=",$PASSMARK_JSON"
    fi
}

function parse_passmark_results {
    # Extract results using awk
    PASSMARK_RESULTS=$(awk '/Results:/,/SystemInformation:/' "$PASSMARK_PATH/PerformanceTest/results_all.yml")
    
    # Parse individual results
    PASSMARK_CPU_MARK=$(echo "$PASSMARK_RESULTS" | awk '/SUMM_CPU:/ {print int($2)}')
    PASSMARK_MEMORY_MARK=$(echo "$PASSMARK_RESULTS" | awk '/SUMM_ME:/ {print int($2)}')
    
    # Create JSON array for PassMark results
    PASSMARK_JSON='"passmark":{'
    PASSMARK_JSON+='"CPU Mark":'$PASSMARK_CPU_MARK
    PASSMARK_JSON+=',"Memory Mark":'$PASSMARK_MEMORY_MARK
    PASSMARK_JSON+=',"CPU":{
        "Integer Math":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_INTEGER_MATH:/ {print int($2)}')"',
        "Floating Point Math":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_FLOATINGPOINT_MATH:/ {print int($2)}')"',
        "Prime Numbers":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_PRIME:/ {print int($2)}')"',
        "Sorting":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_SORTING:/ {print int($2)}')"',
        "Encryption":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_ENCRYPTION:/ {print int($2)}')"',
        "Compression":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_COMPRESSION:/ {print int($2)}')"',
        "Single Thread":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_SINGLETHREAD:/ {print int($2)}')"',
        "Physics":'"$(echo "$PASSMARK_RESULTS" | awk '/CPU_PHYSICS:/ {print int($2)}')"'
    }'
    PASSMARK_JSON+=',"Memory":{
        "Database Operations":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_ALLOC_S:/ {print int($2)}')"',
        "Read Cached":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_READ_S:/ {print int($2)}')"',
        "Read Uncached":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_READ_L:/ {print int($2)}')"',
        "Write":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_WRITE:/ {print int($2)}')"',
        "Available RAM":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_LARGE:/ {print int($2)}')"',
        "Latency":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_LATENCY:/ {print int($2)}')"',
        "Threaded":'"$(echo "$PASSMARK_RESULTS" | awk '/ME_THREADED:/ {print int($2)}')"'
    }'
    PASSMARK_JSON+='}'
    
    # Add PassMark results to the main JSON result
    if [ ! -z $JSON ]; then
        JSON_RESULT+=",$PASSMARK_JSON"
    fi
}

# Add PassMark test execution in the main script flow
if [ -z "$SKIP_PASSMARK" ]; then
    run_passmark
fi

function install_cpuminer() {
    echo -e "\nInstalling cpuminer-multi..."
    
    CPUMINER_PATH=$YABS_PATH/cpuminer-multi
    git clone https://github.com/tpruvot/cpuminer-multi "$CPUMINER_PATH"
    
    if [ ! -d "$CPUMINER_PATH" ]; then
        echo "Failed to clone cpuminer-multi repository. Skipping cpuminer test."
        return 1
    fi
    
    pushd "$CPUMINER_PATH" > /dev/null
    ./build.sh
    popd > /dev/null
    
    if [ ! -f "$CPUMINER_PATH/cpuminer" ]; then
        echo "Failed to build cpuminer. Skipping cpuminer test."
        return 1
    fi
    
    return 0
}

function run_cpuminer() {
    echo -e "\nRunning cpuminer-multi benchmark..."
    
    CPUMINER_PATH=$YABS_PATH/cpuminer-multi
    pushd "$CPUMINER_PATH" > /dev/null
    
    CPUMINER_OUTPUT=$(./cpuminer --benchmark --cpu-priority=2 --time-limit=$CPUMINER_TEST_DURATION)
    
    popd > /dev/null
    
    parse_cpuminer_results "$CPUMINER_OUTPUT"
}

function parse_cpuminer_results() {
    local CPUMINER_OUTPUT="$1"
    local CPUMINER_JSON='"cpuminer-multi":{'
    CPUMINER_JSON+='"single-core":{'
    
    local total_cores=0
    local total_performance=0
    declare -A cpu_results

    while IFS= read -r line; do
        if [[ $line =~ CPU\ #([0-9]+):\ ([0-9.]+)\ kH/s ]]; then
            cpu_num="${BASH_REMATCH[1]}"
            performance="${BASH_REMATCH[2]}"
            cpu_results[$cpu_num]=$performance
        fi
    done <<< "$CPUMINER_OUTPUT"
    
    echo -e "\ncpuminer-multi Benchmark Results:"
    echo -e "---------------------------------"
    echo -e "Single-core results:"
    
    for cpu_num in "${!cpu_results[@]}"; do
        performance="${cpu_results[$cpu_num]}"
        CPUMINER_JSON+="\"cpu_$cpu_num\":$performance,"
        total_cores=$((total_cores + 1))
        total_performance=$(awk "BEGIN {print $total_performance + $performance}")
        echo -e "  CPU #$cpu_num: $performance kH/s"
    done
    
    # Calculate average and round to 2 decimal places
    local average=$(awk "BEGIN {printf \"%.2f\", $total_performance / $total_cores}")
    CPUMINER_JSON+="\"average\":$average"
    
    echo -e "  Average: $average kH/s"
    
    CPUMINER_JSON+='},"multi-core":{'
    
    if [[ $CPUMINER_OUTPUT =~ Benchmark:\ ([0-9.]+)\ kH/s ]]; then
        benchmark="${BASH_REMATCH[1]}"
        CPUMINER_JSON+="\"benchmark\":$benchmark"
    else
        benchmark="0"
        CPUMINER_JSON+="\"benchmark\":0"
    fi
    
    echo -e "\nMulti-core result:"
    echo -e "  Benchmark: $benchmark kH/s"
    
    CPUMINER_JSON+='}}'
    
    # Add cpuminer results to the main JSON result
    if [ ! -z $JSON ]; then
        JSON_RESULT+=",$CPUMINER_JSON"
    fi
}

if [ -z "$SKIP_CPUMINER" ]; then
    if install_cpuminer; then
        run_cpuminer
    fi
fi

# finished all tests, clean up all YABS files and exit
echo -e
rm -rf "$YABS_PATH"

# Restore original CPU settings
if [ -z "$SkipGovernors" ]; then
    restore_cpu_settings
fi

YABS_END_TIME=$(date +%s)

# calculate_time_taken
# Purpose: This method is designed to find the time taken for the completion of a YABS run.
# Parameters:
#          1. YABS_END_TIME - time when GB has completed and all files are removed
#          2. YABS_START_TIME - time when YABS is started
function calculate_time_taken() {
	end_time=$1
	start_time=$2

	time_taken=$(( ${end_time} - ${start_time} ))
	if [ ${time_taken} -gt 60 ]; then
		min=$(expr $time_taken / 60)
		sec=$(expr $time_taken % 60)
		echo "YABS completed in ${min} min ${sec} sec"
	else
		echo "YABS completed in ${time_taken} sec"
	fi
	[[ ! -z $JSON ]] && JSON_RESULT+=',"runtime":{"start":'$start_time',"end":'$end_time',"elapsed":'$time_taken'}'
}

calculate_time_taken $YABS_END_TIME $YABS_START_TIME

if [[ ! -z $JSON ]]; then
	JSON_RESULT+='}'

	# write json results to file
	if [[ $JSON = *w* ]]; then
		echo "$JSON_RESULT" | python3 -m json.tool > "$JSON_FILE"
	fi

	# send json results
	if [[ $JSON = *s* ]]; then
		IFS=',' read -r -a JSON_SITES <<< "$JSON_SEND"
		for JSON_SITE in "${JSON_SITES[@]}"
		do
			if [[ ! -z $LOCAL_CURL ]]; then
				curl -s -H "Content-Type:application/json" -X POST --data "$JSON_RESULT" $JSON_SITE
			else
				wget -qO- --post-data="$JSON_RESULT" --header='Content-Type:application/json' $JSON_SITE
			fi
		done
	fi

	# print json result to screen
	if [[ $JSON = *j* ]]; then
		echo -e
		echo "$JSON_RESULT" | python3 -m json.tool
	fi
fi

# reset locale settings
unset LC_ALL
