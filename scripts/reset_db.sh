#!/bin/bash

print_yellow() {
  echo -e "\033[0;33m$1\033[0m"
}


print_yellow "WARNING: This will permanently delete all Free Sleep biometric data!"
print_yellow "After deleting, this will recreate the DB"
read -p "Are you sure you want to continue? (y/N): " confirm


if [[ "$confirm" =~ ^[Yy]$ ]]; then
  systemctl stop free-sleep free-sleep-stream
  rm -f /persistent/free-sleep-data/free-sleep.db-shm \
        /persistent/free-sleep-data/free-sleep.db-wal \
        /persistent/free-sleep-data/free-sleep.db-journal \
        /persistent/free-sleep-data/free-sleep.db

  su - dac -c "cd /home/dac/free-sleep/server && /home/dac/.volta/bin/npm run migrate:deploy && exit"

  systemctl start free-sleep free-sleep-stream
else
    echo "Cancelled"
fi
