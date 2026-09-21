#!/bin/bash

# Directory where your session files are stored
SESSION_DIR="$HOME/mlange/tmux/sessions" # Change this to your session directory

# Check if the session directory exists
if [ ! -d "$SESSION_DIR" ]; then
  echo "Session directory does not exist: $SESSION_DIR"
  exit 1
fi

# Create an array of session files
sessions=()
while IFS= read -r -d '' file; do
  sessions+=("$(basename "$file")")
done < <(find "$SESSION_DIR" -type f -name "*.sh" -print0)

# Check if there are any session files
if [ ${#sessions[@]} -eq 0 ]; then
  echo "No session files found in $SESSION_DIR"
  exit 1
fi

# Display the selection menu
echo "Select a session to start:"
select session in "${sessions[@]}"; do
  if [[ -n "$session" ]]; then
    # Start the selected session
    tmux source-file "$SESSION_DIR/$session"
    break
  else
    echo "Invalid selection. Please try again."
  fi
done
