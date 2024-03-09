#!/bin/bash
# execute nohup ./ext_smart_test.sh &
# check status with tail -f nohup.out
# end process by doing ps aux | grep ext_smart_test.sh then kill PID


# Directory where you want to save the test results
RESULT_DIR="<results_dir>"

# Ensure the RESULT_DIR exists
mkdir -p "$RESULT_DIR"

# Combine listing of nvme and sd* drives
for drive in $(lsblk -nd --output NAME | egrep 'nvme|sd'); do
  echo "Starting extended SMART test on /dev/$drive..."
  # Start the extended SMART test
  smartctl -t long /dev/$drive

  # Wait for the test to complete
  echo "Test started for /dev/$drive, waiting for completion..."
  sleep 1 # Sleep for 1 second to ensure the smartctl command initiates the test before checking the status
  while [ "$(smartctl -c /dev/$drive | grep 'Self-test execution status' | awk '{print $6}')" != "0" ]; do
    echo "Test still running for /dev/$drive..."
    sleep 60 # Check every 60 seconds
  done

  echo "Test completed for /dev/$drive. Saving the result..."
  # Save the test result to a file in the specified directory
  smartctl -a /dev/$drive > "$RESULT_DIR/${drive}_smart_result.txt"
done

echo "All tests completed and results saved in $RESULT_DIR."
