# Commits the product strategy documents to the PRIVATE docs repo.
#
# CLAUDE.md, COMMUTE_GUARDIAN_HANDOVER.md and the wireframes PDF live in this
# working tree but are gitignored in the public code repo, deliberately: that
# repo is public and these carry the monetization design, the kill floor, the
# positioning and the owner's own context.
#
# They are tracked from a SEPARATE GIT DIR rather than copied, so there is
# exactly one copy of each file and nothing can drift. CLAUDE.md especially has
# to stay where it is or the project instructions stop loading.
#
#   powershell -ExecutionPolicy Bypass -File tool\docs.ps1 "why this changed"
#
# The ExecutionPolicy flag is not optional on this machine: unsigned local
# scripts are blocked by default, and `.\tool\docs.ps1` fails with
# UnauthorizedAccess.
#
# With no message it just reports what has changed since the last docs commit.

param([string]$Message)

$gitDir = "C:\dev\commute-guardian-docs.git"
$workTree = "C:\dev\commute-guardian"
$docs = @(
  "CLAUDE.md",
  "COMMUTE_GUARDIAN_HANDOVER.md",
  "Commute-Guardian-Wireframes.pdf"
)

if (-not (Test-Path $gitDir)) {
  Write-Output "No docs repo at $gitDir. Clone https://github.com/ShashankBallaya/commute-guardian-docs first."
  exit 1
}

if (-not $Message) {
  # -f because the code repo's .gitignore hides these from every git that reads it.
  git --git-dir=$gitDir --work-tree=$workTree add -f $docs
  git --git-dir=$gitDir --work-tree=$workTree status --short
  Write-Output ""
  Write-Output 'Pass a message to commit: .\tool\docs.ps1 "why this changed"'
  exit 0
}

git --git-dir=$gitDir --work-tree=$workTree add -f $docs
git --git-dir=$gitDir --work-tree=$workTree commit -m $Message
if ($?) { git --git-dir=$gitDir --work-tree=$workTree push -q origin main }
