#!/bin/bash
# Builds a fresh test environment covering every outcome of logarchive.sh
rm -rf Active Archive Backup logarchive.log
mkdir -p Active Backup Active/subdir

old() { touch -d "$1 days ago" "$2"; }   # old <days> <file>

# ---- CASE A: ARCHIVED (old, no backup yet -> script makes backup -> identical) ----
for i in 1 2 3; do echo "app log line $i" > Active/app$i.log; old 10 Active/app$i.log; done
for i in 1 2; do echo "note $i" > Active/notes$i.txt; old 15 Active/notes$i.txt; done
echo "spaced name" > "Active/my server.log"; old 9 "Active/my server.log"
head -c 20000 /dev/urandom | base64 > Active/big_old.log; old 30 Active/big_old.log
: > Active/empty_old.log; old 12 Active/empty_old.log

# ---- CASE B: ARCHIVED (old, correct pre-existing independent backup copy) ----
echo "already backed up" > Active/prebacked.log; old 20 Active/prebacked.log
cp -p Active/prebacked.log Backup/prebacked.log

# ---- CASE C: KEPT - backup missing (rc=1): backup path is a directory, so cp skipped and -f fails ----
echo "backup missing" > Active/nobackup.log; old 11 Active/nobackup.log
mkdir -p Backup/nobackup.log
echo "txt variant" > Active/nobackup2.txt; old 11 Active/nobackup2.txt
mkdir -p Backup/nobackup2.txt

# ---- CASE D: KEPT - same inode / hard link (rc=2) ----
echo "hardlinked" > Active/hard.log; old 14 Active/hard.log
ln Active/hard.log Backup/hard.log
echo "hardlinked txt" > Active/hard2.txt; old 14 Active/hard2.txt
ln Active/hard2.txt Backup/hard2.txt

# ---- CASE E: KEPT - backup content differs (rc=3) ----
echo "version NEW" > Active/diff.log; old 18 Active/diff.log
echo "version OLD" > Backup/diff.log
echo "txt NEW" > Active/diff2.txt; old 18 Active/diff2.txt
echo "txt OLD, longer content" > Backup/diff2.txt
echo "line1" > Active/diff_subtle.log; old 18 Active/diff_subtle.log
echo "line2" > Backup/diff_subtle.log        # same size, different bytes

# ---- CASE F: IGNORED - not old enough ----
echo fresh > Active/fresh.log; touch Active/fresh.log
echo "6 days" > Active/sixdays.txt; old 6 Active/sixdays.txt

# ---- CASE G: IGNORED - wrong extension / subdir ----
echo csv > Active/data.csv; old 40 Active/data.csv
echo conf > Active/old.conf; old 40 Active/old.conf
echo nested > Active/subdir/nested.log; old 40 Active/subdir/nested.log

# ---- CASE I: ARCHIVED - hidden file (find matches dotfiles too) ----
echo hidden > Active/.hidden.log; old 25 Active/.hidden.log

# ---- CASE H: archive-name collision (same name already in Archive/log) ----
mkdir -p Archive/log
echo "old archived copy" > Archive/log/collide.log
echo "new collide" > Active/collide.log; old 22 Active/collide.log

echo "Test environment ready:"; find Active Backup Archive -mindepth 1 | sort
