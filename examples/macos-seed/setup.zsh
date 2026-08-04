#!/bin/zsh
# Runs inside the simulated Mac, as Learner, after everything else is in place.
# Use it for anything that wants the Mac's own commands rather than file copies.
set -u

# Backdate a file so `ls -lt` has something to order.
touch -t 202401150930 ~/Desktop/report/notes.txt

# Seed the fake clipboard.
print -n 'revenue: 41200' | pbcopy

# Record a preference the task can ask the learner to read back.
defaults write com.example.report lastOpened -string '2024-01-15'
