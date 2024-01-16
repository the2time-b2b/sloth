# Resets to the previous commit and force push any current changes with the same commit message(s).
resetBranch=$(git log | grep "^commit" -m 2 | tail -n 1 | awk -F " " '{ print $NF }')
commitLogsLineCount=$(git log | grep "^commit" -m 2 -n | awk -F: '{ print $1 }' | tail -n 1)
commitMessages=$(git log | grep "^commit" -m 1 -A $(($commitLogsLineCount - 2)) | tail -n +5 | sed 's/^[ \t]*//' | tr -s '\n')
commitMessagesOverwrite=""

eval git reset $resetBranch
eval git add .

while IFS= read -r result
do
  if [ "$commitMessages" == "" ]
  then
    commitMessagesOverwrite=" -a --allow-empty-message -m \"\""
    break
  fi
  commitMessagesOverwrite+=" -m \"$result\""
done < <(echo "$commitMessages")

eval git commit $commitMessagesOverwrite

branchName=$(git branch --list | tail -n +1 | awk -F " " '{ print $NF }')
eval git push --force origin $branchName

