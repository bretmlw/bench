# BretBench

This script automates the execution of the best benchmarking tools in the industry. Included are several tests to check the performance of critical areas of a server: disk performance with [fio](https://github.com/axboe/fio), network performance with [iperf3](https://github.com/esnet/iperf), and CPU/memory performance with [Geekbench](https://www.geekbench.com/). The script is designed to not require any external dependencies to be installed nor elevated privileges to run. If there are any features that you would like to see added, feel free to submit an issue describing your feature request or fork the project and submit a PR

## How to Run

```
TBC
```

### Flags (Skipping Tests, Reducing iperf Locations, Geekbench 4/5/6, etc.)

```
curl -sL yabs.sh | bash -s -- -flags
```

| Flag | Description |
| ---- | ----------- |
| -b | Forces use of pre-compiled binaries from repo over local packages |
| -f/-d | Disables the fio (disk performance) test |
| -i | Disables the iperf (network performance) test |
| -g | Disables the Geekbench (system performance) test |
| -n | Skips the network information lookup and print out |
| -h | Prints the help message with usage, flags detected, and local package (fio/iperf) status |
| -9 | Runs both the Geekbench 4 and 5 tests instead of the Geekbench 6 test |
| -6 | Re-enables the Geekbench 6 test if any of the following were used: -4, -5, or -9 (-6 flag must be last to not be overridden) |
| -j | Prints a JSON representation of the results to the screen |
| -w \<filename\> | Writes the JSON results to a file using the file name provided |
| -s \<url\> | Sends a JSON representation of the results to the designated URL(s) (see section below) |
| -p | Disables the checking and setting (to performance) of the CPU governor/policy |

Options can be grouped together to skip multiple tests, i.e. `-fg` to skip the disk and system performance tests (effectively only testing network performance).

**Geekbench License Key**: A Geekbench license key can be utilized during the Geekbench test to unlock all features. Simply put the email and key for the license in a file called _geekbench.license_. `echo "email@domain.com ABCDE-12345-FGHIJ-57890" > geekbench.license`

### Submitting JSON Results  (PLANNED)

Results from running this script can be sent to your benchmark results website of choice in JSON format. Invoke the `-s` flag and pass the URL to where the results should be submitted to:

```
curl -sL yabs.sh | bash -s -- -s "https://example.com/yabs/post"
```

JSON results can be sent to multiple endpoints by entering each site joined by a comma (e.g. "https://example.com/yabs/post,http://example.com/yabs2/post").



Example JSON output: [example.json](bin/example.json).

## TO-DO
### General Script Updates
- Wait for load average to be under X before starting the tests
- Add monitoring (CPU temperature, frequency, and power consumption via Odroid SmartPower 3)
- Function to install all required software packages (iperf3, fio etc)
### Benchmarks to add
- UnixBench
- PassMark PerformanceTest
- cpubench-multi

### fio
- Modify tests and output to use read, write, random read, and random write rather than mixed.
- Add functionality to define an array of partitions to test, so machines with microSD, USB SSD, NVMe etc can all be tested in one test run.
### iperf3
- Modify test runtime from 10s to 60s
- Add functionality to define an array of interfaces to test so machines with WiFi and Ethernet can be tested in one test run
### Geekbench 6
- Add functionality to run test X times and take the average of those test runs

## Known Issues
- APT Package install detection doesn't work if command is not the same as the apt package name (lscpu being part of utils-linux for example so it checks if lscpu will run, which it does, but it's not the same as the package name so wouldn't be installed if it wasn't already installed)

## Tests Conducted

 - **[fio](https://github.com/axboe/fio)** - Disk benchmark covering 4, 8, 64, 512KB, and 1/16MB block sizes across read, write, random read, and random write tests. Tests run on a 512MB test file for 30 seconds.
 - **[iperf3](https://github.com/esnet/iperf)** - Network benchmark which tests both download and upload to a local endpoint on a 1, or 2.5GbE connection depending on the device. If a device has a WiFi interface, this is also tested.
 - **[Geekbench 6.3.0](https://www.geekbench.com/)** - Geekbench 6.3.0 ARM Preview is used to perform a range of tests. Not the best of benchmarks as it relies heavily on software which differs from machine to machine but in the SBC world a lot of people are using the same images from the vendor, so it's a test that can be used, and taken with a large grain of salt.

## Example Output

```
ADD WHEN FINISHED
```

## Acknowledgements

This script was forked from Yet-Another-Bench-Script (YABS) and modified to suit my requirements for SBC benchmarking.

## License
```
 whatever
```
