#!/bin/bash
# use this script to automate plex db backups to occur more often than the default 3 days using cron
# Replace <YOUR_PLEX_IP> with your Plex server IP and <YOUR_PLEX_TOKEN> with your actual token
PLEX_IP="<YOUR_PLEX_IP>"
PLEX_TOKEN="<YOUR_PLEX_TOKEN>"

# Directory where you want to save backups. Ensure it exists or create it.
BACKUP_DIR="/path/to/backup"

# Filename with date and time
FILENAME="pms_database_$(date +%F-%T).zip"

# Set Maximum Backups to keep
MAX_BACKUPS=7

echo "Starting backup process..."

# Use curl with progress meter (-#) for large downloads
if curl -k -# "https://${PLEX_IP}:32400/diagnostics/databases?X-Plex-Token=${PLEX_TOKEN}" --output "${BACKUP_DIR}/${FILENAME}"; then
  echo "Backup successful: ${FILENAME}"

  echo "Checking for old backups to clean up..."
  # Count the number of backup files
  BACKUP_COUNT=$(ls -1 ${BACKUP_DIR}/pms_database_*.zip | wc -l)
  

  # Check if the number of backups is greater than the maximum allowed
  if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    # Calculate how many backups to delete
    DELETE_COUNT=$(($BACKUP_COUNT - $MAX_BACKUPS))

    # Delete the oldest backups
    echo "Deleting $DELETE_COUNT old backup(s)..."
    ls -1tr ${BACKUP_DIR}/pms_database_*.zip | head -n "$DELETE_COUNT" | xargs rm -f
    echo "$DELETE_COUNT old backup(s) deleted."
  else
    echo "No old backups need to be deleted."
  fi
else
  echo "Backup failed."
fi

echo "Backup process completed."
